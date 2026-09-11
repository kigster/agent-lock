# frozen_string_literal: true

require "redis"

# The Redis store is opt-in, so this runs only where a Redis is actually
# reachable. It is the same contract the file store satisfies, asserted
# against a real server rather than a double, because the two things this
# backend exists for, an atomic SET NX and a TTL that expires an abandoned
# lock, are exactly what a double would fake.
#
# RedisHelpers::TEST_REDIS_URL, fixed rather than read from REDIS_URL, so the
# suite never writes into whatever database a developer's own Redis work, or
# an unrelated REDIS_URL left over in the shell, lives in.
RSpec.describe Agent::Lock::Store::RedisStore, type: :checkout do
  subject(:store) { described_class.new(tree, client: redis) }

  let(:url) { RedisHelpers::TEST_REDIS_URL }
  let(:redis) { ::Redis.new(url: url) }
  let(:identity) { Agent::Lock::Identity.new(env: { "AGENT_ID" => "luke-backend" }) }
  let(:scope) { Agent::Lock::Scope.parse("workflow/**", tree: tree) }
  let(:record) do
    Agent::Lock::Record.build(scope: scope, tree: tree, identity: identity, intent: "rewriting the installer")
  end

  before do
    skip "no Redis on #{url}" unless redis_reachable?(url)
  end

  after do
    next unless redis_reachable?(url)

    store.all.each { |existing| store.delete(existing) }
    redis.del(store.mutex_key)
  end

  it "round-trips a lock through Redis without losing a field" do
    store.create(record)

    found = store.find(scope)

    aggregate_failures do
      expect(found.agent_id).to eq("luke-backend")
      expect(found.scope).to eq("workflow/**")
      expect(found.intent).to eq("rewriting the installer")
    end
  end

  # The reason to reach for Redis at all: SET NX settles a race between two
  # machines, which no amount of care with a shared filesystem can.
  it "lets exactly one of two racing claims win" do
    results = [store.create(record), store.create(record)]

    expect(results).to contain_exactly(true, false)
  end

  it "sees the lock in a listing" do
    store.create(record)

    expect(store.all.map(&:scope)).to eq(["workflow/**"])
  end

  it "gives it back on delete" do
    store.create(record)
    store.delete(record)

    aggregate_failures do
      expect(store.find(scope)).to be_nil
      expect(store.create(record)).to be(true)
    end
  end

  it "replaces a lock in place when its notes change" do
    store.create(record)
    store.update(record.note("halfway"))

    expect(store.find(scope).intent).to include("halfway")
  end

  describe "chosen deliberately, never guessed" do
    it "refuses to switch a tree that already has locks in the other backend" do
      Agent::Lock::Store.claim(tree, "file")

      expect { with_env("AGENT_LOCK_BACKEND" => "redis") { Agent::Lock::Store.for(tree) } }
        .to raise_error(Agent::Lock::Store::Mismatch, /release them before switching/)
    end

    it "builds the backend the environment asks for" do
      with_env("AGENT_LOCK_BACKEND" => "redis") do
        expect(Agent::Lock::Store.for(tree)).to be_a(described_class)
      end
    end
  end

  # The store-wide mutex, asserted on its own rather than only through
  # Manager, so that a regression here names the mutex instead of surfacing as
  # one overlapping lock in a race that happens to go the wrong way.
  describe "#synchronize" do
    it "hands back whatever the block returns" do
      expect(store.synchronize { :done }).to eq(:done)
    end

    # A mutex that `all` could see would be parsed as a lock on every scan,
    # and a mutex in the namespace would be deleted by anything sweeping it.
    it "keeps its mutex out of the keys a listing scans" do
      store.create(record)

      seen = store.synchronize do
        { exists: redis.exists?(store.mutex_key), scopes: store.all.map(&:scope) }
      end

      aggregate_failures do
        expect(seen).to eq(exists: true, scopes: ["workflow/**"])
        expect(redis.scan_each(match: "#{store.key_for("")}*").to_a).not_to include(store.mutex_key)
      end
    end

    # The lease is what frees the store when a holder dies mid-claim, which
    # is the one thing a Redis key cannot learn by itself.
    it "leases the mutex rather than holding it forever" do
      ttl = store.synchronize { redis.pttl(store.mutex_key) }

      expect(ttl).to be_between(1, described_class::MUTEX_LEASE_MS)
    end

    it "gives the mutex back afterwards, and when the block raises" do
      store.synchronize { nil }
      after_success = redis.exists?(store.mutex_key)
      expect { store.synchronize { raise "boom" } }.to raise_error(RuntimeError, "boom")

      expect([after_success, redis.exists?(store.mutex_key)]).to eq([false, false])
    end

    # Each process reads a counter, dawdles, and writes it back plus one.
    # Without mutual exclusion two of them read the same value and one
    # increment is lost, which is the scan-then-create race in miniature.
    it "lets one process at a time into the critical section" do
      counter = File.join(checkout, "counter")
      File.write(counter, "0")

      statuses = Array.new(4) { fork_incrementer(counter, rounds: 25) }.map { |pid| Process.wait2(pid).last }

      aggregate_failures do
        expect(statuses).to all(be_success)
        expect(File.read(counter).to_i).to eq(100)
      end
    end

    it "gives up with an error, rather than hanging an agent forever, when somebody else holds it" do
      redis.set(store.mutex_key, "somebody-else", px: 10_000)
      entered = false

      with_env("AGENT_LOCK_MUTEX_TIMEOUT" => "0.2") do
        expect { store.synchronize { entered = true } }
          .to raise_error(Agent::Lock::Error, /timed out after 0.2s.*#{Regexp.escape(store.mutex_key)}/)
      end

      expect([entered, redis.get(store.mutex_key)]).to eq([false, "somebody-else"])
    end

    it "gets in once a dead holder's lease runs out" do
      redis.set(store.mutex_key, "crashed-holder", px: 100)

      with_env("AGENT_LOCK_MUTEX_TIMEOUT" => "2") do
        expect(store.synchronize { :in }).to eq(:in)
      end
    end

    # The lease ran out mid-block and somebody else took the mutex. Deleting
    # it now would let a third process in beside the second, and carrying on
    # quietly would hide that this block ran unprotected for a while.
    it "never deletes a mutex it no longer owns, and says the block overran" do
      expect { store.synchronize { redis.set(store.mutex_key, "the-next-holder") } }
        .to raise_error(Agent::Lock::Error, /lease/)

      expect(redis.get(store.mutex_key)).to eq("the-next-holder")
    end
  end

  # @return [Integer] the child's pid
  def fork_incrementer(counter, rounds:)
    fork do
      mine = described_class.new(Agent::Lock::Tree.for(checkout), client: ::Redis.new(url: url))
      rounds.times do
        mine.synchronize do
          value = File.read(counter).to_i
          sleep 0.001
          File.write(counter, (value + 1).to_s)
        end
      end
      exit!(0)
    rescue StandardError
      exit!(1)
    end
  end
end

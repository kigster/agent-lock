# frozen_string_literal: true

require "redis"

# The Redis store is opt-in, so this runs only where a Redis is actually
# reachable. It is the same contract the file store satisfies, asserted
# against a real server rather than a double, because the two things this
# backend exists for, an atomic SET NX and a TTL that expires an abandoned
# lock, are exactly what a double would fake.
RSpec.describe Agent::Lock::Store::Redis, type: :checkout do
  subject(:store) { described_class.new(tree) }

  let(:identity) { Agent::Lock::Identity.new(env: { "AGENT_ID" => "luke-backend" }) }
  let(:scope) { Agent::Lock::Scope.parse("workflow/**", tree: tree) }
  let(:record) do
    Agent::Lock::Record.build(scope: scope, tree: tree, identity: identity, intent: "rewriting the installer")
  end

  before do
    skip "no Redis on #{ENV.fetch("REDIS_URL", "127.0.0.1:6379")}" unless redis_running?
  end

  after { store.all.each { |existing| store.delete(existing) } }

  def redis_running?
    ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"), timeout: 0.2).ping == "PONG"
  rescue StandardError
    false
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
      Agent::Lock::Store.record(tree, "file")

      expect { with_env("AGENT_LOCK_BACKEND" => "redis") { Agent::Lock::Store.for(tree) } }
        .to raise_error(Agent::Lock::Store::Mismatch, /release them before switching/)
    end

    it "builds the backend the environment asks for" do
      with_env("AGENT_LOCK_BACKEND" => "redis") do
        expect(Agent::Lock::Store.for(tree)).to be_a(described_class)
      end
    end

    def with_env(pairs)
      previous = pairs.transform_values { |_| nil }.merge(ENV.slice(*pairs.keys))
      ENV.update(pairs)
      yield
    ensure
      pairs.each_key { |key| previous[key] ? ENV[key] = previous[key] : ENV.delete(key) }
    end
  end
end

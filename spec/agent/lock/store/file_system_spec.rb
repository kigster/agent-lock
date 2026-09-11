# frozen_string_literal: true

# The store-wide mutex, asserted on its own rather than only through Manager,
# so that a regression here names the mutex instead of surfacing as one
# overlapping lock in a race that happens to go the wrong way.
RSpec.describe Agent::Lock::Store::FileSystem, type: :checkout do
  subject(:store) { described_class.new(tree) }

  let(:mutex) { File.join(store.dir, described_class::MUTEX) }

  def with_env(pairs)
    previous = ENV.slice(*pairs.keys)
    ENV.update(pairs)
    yield
  ensure
    pairs.each_key { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end

  describe "#synchronize" do
    it "hands back whatever the block returns" do
      expect(store.synchronize { :done }).to eq(:done)
    end

    it "creates the store and its mutex the first time it is asked" do
      FileUtils.rm_rf(store.dir)

      store.synchronize { nil }

      expect(File.file?(mutex)).to be(true)
    end

    # The mutex sits in the same directory as the locks. A listing that read
    # it as one would either choke on it or, worse, count it.
    it "never lists the mutex as a lock" do
      scope = Agent::Lock::Scope.parse("workflow/**", tree: tree)
      identity = Agent::Lock::Identity.new(env: { "AGENT_ID" => "luke-backend" })
      store.create(Agent::Lock::Record.build(scope: scope, tree: tree, identity: identity, intent: "installer"))

      scopes = store.synchronize { store.all.map(&:scope) }

      expect(scopes).to eq(["workflow/**"])
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

    it "gives the mutex back when the block raises" do
      expect { store.synchronize { raise "boom" } }.to raise_error(RuntimeError, "boom")

      with_env("AGENT_LOCK_MUTEX_TIMEOUT" => "0.2") do
        expect(store.synchronize { :again }).to eq(:again)
      end
    end

    # flock locks belong to an open file description, not to a process, so a
    # second descriptor held here stands in for another agent mid-claim.
    it "gives up with an error, rather than hanging an agent forever, when somebody else holds it" do
      store.synchronize { nil }
      entered = false

      File.open(mutex, File::RDWR) do |held|
        held.flock(File::LOCK_EX)

        with_env("AGENT_LOCK_MUTEX_TIMEOUT" => "0.2") do
          expect { store.synchronize { entered = true } }
            .to raise_error(Agent::Lock::Error, /timed out after 0.2s.*#{Regexp.escape(mutex)}/)
        end
      end

      expect(entered).to be(false)
    end
  end

  # @return [Integer] the child's pid
  def fork_incrementer(counter, rounds:)
    fork do
      mine = described_class.new(Agent::Lock::Tree.for(checkout))
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

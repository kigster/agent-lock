# frozen_string_literal: true

require "redis"

# The race 0.1.0 lost. Manager#acquire scans the store for anything
# overlapping and then creates a record, and O_EXCL or SET NX only make the
# create atomic for one scope key. `lib/**` and `lib/a1.rb` are two keys, so
# two agents asking at the same moment both saw an empty store and both won:
# ten wide claims against ten narrow ones left 9 to 11 overlapping locks, on
# both backends.
#
# Every claimant here is a process of its own, as it is in real life, and
# they are held at a gate until all of them are ready, so that they really do
# ask at once rather than one after another as fork happens to schedule them.
RSpec.describe "claiming overlapping scopes at the same moment", type: :checkout do
  let(:claims) do
    (1..10).flat_map { |n| [["wide-#{n}", "lib/**"], ["narrow-#{n}", "lib/a#{n}.rb"]] }
  end

  # @param claims [Array<Array(String, String)>] agent id and the path it wants
  # @yieldparam id [String]
  # @yieldreturn [Agent::Lock::Manager] built in the child, before the gate
  # @return [Hash{String => String}] each agent id and the status it got back
  def race(claims, &)
    gate, opener = IO.pipe
    reports, reporter = IO.pipe

    pids = claims.map { |id, path| claimant(id, path, gate:, reporter:, unused: [opener, reports], &) }

    [gate, reporter, opener].each(&:close) # the last close opens the gate
    pids.each { |pid| Process.wait(pid) }
    reports.read.lines(chomp: true).to_h { |line| line.split(" ", 2) }
  end

  # @return [Integer] the child's pid
  def claimant(id, path, gate:, reporter:, unused:)
    fork do
      unused.each(&:close)
      manager = yield(id)
      gate.read # returns only once every copy of the write end is closed
      reporter.puts("#{id} #{manager.acquire(path, intent: "racing").status}")
    rescue StandardError => e
      reporter.puts("#{id} #{e.class}: #{e.message}")
    ensure
      exit!(0)
    end
  end

  # The narrow scopes are disjoint from each other, so there are exactly two
  # honest outcomes: a wide claim got there first and holds the tree alone, or
  # a narrow one did, every narrow claim won, and every wide one was refused.
  # Anything else is two agents holding overlapping scopes at once.
  shared_examples "no two overlapping claims both win" do
    it "records only claims that do not overlap one another" do
      outcomes = race(claims) { |id| manager_for(id, store: build_store) }
      winners = outcomes.select { |_id, status| status == "acquired" }.keys
      active = build_store.all.select(&:active?)
      overlapping = active.combination(2).select { |one, two| one.scope_object.conflicts_with?(two.scope_object) }

      aggregate_failures do
        expect(outcomes.values - %w[acquired held]).to be_empty
        expect(winners.map { |id| id[/\A[a-z]+/] }.tally).to eq("wide" => 1).or eq("narrow" => 10)
        expect(active.map(&:agent_id)).to match_array(winners)
        expect(overlapping.map { |pair| pair.map(&:scope) }).to be_empty
      end
    end
  end

  context "with the file store" do
    def build_store = Agent::Lock::Store::FileSystemStore.new(Agent::Lock::Tree.for(checkout))

    include_examples "no two overlapping claims both win"
  end

  context "with the Redis store" do
    let(:url) { ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/15") }

    def build_store = Agent::Lock::Store::RedisStore.new(Agent::Lock::Tree.for(checkout), client: Redis.new(url: url))

    before do
      skip "no Redis on #{url}" unless redis_running?
    end

    after do
      build_store.then { |store| store.all.each { |record| store.delete(record) } } if redis_running?
    end

    def redis_running?
      Redis.new(url: url, timeout: 0.2).ping == "PONG"
    rescue StandardError
      false
    end

    include_examples "no two overlapping claims both win"
  end
end

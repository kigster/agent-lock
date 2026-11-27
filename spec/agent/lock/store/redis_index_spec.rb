# frozen_string_literal: true

require "redis"

# The Redis-wide listing. It has to see every repository in one Redis, which
# a store opened on one checkout does not offer, and it has to ignore that
# store's mutex.
RSpec.describe Agent::Lock::Store::RedisIndex, type: :checkout do
  subject(:index) { described_class.new(redis) }

  let(:url) { RedisHelpers::TEST_REDIS_URL }
  let(:redis) { Redis.new(url: url) }
  let(:major_minor) { Agent::Lock::VERSION.split(".").take(2).join(".") }

  before { skip "no Redis on #{url}" unless redis_reachable?(url) }

  after { redis.flushdb if redis_reachable?(url) }

  def plant(dir, origin, scope, agent)
    system("git", "-C", dir, "remote", "add", "origin", origin, out: File::NULL, err: File::NULL)
    tree = Agent::Lock::Tree.for(dir)
    store = Agent::Lock::Store::RedisStore.new(tree, client: redis)
    parsed = Agent::Lock::Scope.parse(scope, tree: tree)
    identity = Agent::Lock::Identity.new(env: { "AGENT_ID" => agent })
    store.create(Agent::Lock::Record.build(scope: parsed, tree: tree, identity: identity, intent: "working"))
    tree
  end

  describe ".normalize_slug" do
    it "accepts owner/name and a github.com path" do
      expect(described_class.normalize_slug("github.com/kigster/laser-cutter.git")).to eq("kigster/laser-cutter")
    end

    it "refuses a name that is not owner/name" do
      expect { described_class.normalize_slug("laser-cutter") }
        .to raise_error(Agent::Lock::Error, %r{owner/name})
    end
  end

  it "counts one repository's locks and ignores the mutex" do
    plant(checkout, "git@github.com:kigster/laser-cutter.git", "lib/**", "luke")
    Agent::Lock::Store::RedisStore.new(tree, client: redis).synchronize { :held }

    repo = index.repos.find { |row| row.namespace == "alock-#{major_minor}-kigster/laser-cutter" }

    aggregate_failures do
      expect(repo.count).to eq(1)
      expect(repo.bytes).to be > 0
      expect(index.locks("kigster/laser-cutter").map { |lock| lock.record.agent_id }).to eq(["luke"])
    end
  end

  it "does not count a different owner/name that merely ends the same way" do
    plant(checkout, "git@github.com:notkigster/laser-cutter.git", "lib/**", "other")

    expect(index.locks("kigster/laser-cutter")).to be_empty
  end

  it "says unknown for a holder on another machine, and no for a dead pid here" do
    planted = plant(checkout, "git@github.com:kigster/laser-cutter.git", "lib/**", "luke")
    store = Agent::Lock::Store::RedisStore.new(planted, client: redis)
    record = store.all.first
    store.update(record.with(host: "elsewhere"))
    dead = store.all.first

    gone = record.with(host: Socket.gethostname, pid: 2**22, started: "no-such-start")

    expect(described_class.alive(dead)).to eq("unknown")
    expect(described_class.alive(gone)).to eq("no")
  end

  it "is what the facade returns" do
    plant(checkout, "git@github.com:kigster/laser-cutter.git", "docs/**", "rey")
    facade = Agent::Lock::Facade.new(strategies: %w[file])

    expect(facade.show_repo("kigster/laser-cutter", redis_url: url).map { |lock| lock.record.scope }).to eq(["docs/**"])
  end
end

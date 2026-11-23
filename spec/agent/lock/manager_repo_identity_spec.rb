# frozen_string_literal: true

require "fileutils"
require "redis"
require "tmpdir"

# A lock is about a repository and the files in it, not about where somebody's
# checkout sits on disk. These specs stand up two checkouts of one repository
# at different paths, the way two machines would hold it, and point them at
# one store.
RSpec.describe Agent::Lock::Manager, type: :checkout do
  attr_reader :base

  # @param dir [String]
  # @param args [Array<String>]
  # @return [String] stdout, stripped
  def git(dir, *args)
    IO.popen(["git", "-C", dir, *args], err: File::NULL, &:read).to_s.strip
  end

  # @param dir [String]
  # @param origin [String, nil]
  # @return [String] the checkout, realpath'd
  def checkout_at(dir, origin: "git@github.com:example/widgets.git", commit: true)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    git(dir, "init", "-q", "-b", "main")
    git(dir, "remote", "add", "origin", origin) if origin
    File.write(File.join(dir, "lib", "a.rb"), "# a\n")
    if commit
      git(dir, "add", ".")
      # Signing and hooks off: a developer's global config must not decide
      # whether a throwaway repository gets its one commit.
      git(dir, "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
          "-c", "core.hooksPath=/dev/null", "commit", "-q", "--no-verify", "-m", "root")
    end
    File.realpath(dir)
  end

  # @param dir [String]
  # @param id [String]
  # @return [Agent::Lock::Manager]
  def manager_in(dir, id)
    tree = Agent::Lock::Tree.for(dir)
    identity = Agent::Lock::Identity.new(env: { "AGENT_ID" => id })
    Agent::Lock::Manager.new(tree: tree, identity: identity, store: Agent::Lock::Store::FileSystemStore.new(tree))
  end

  around do |example|
    Dir.mktmpdir("agent-lock-repo") do |dir|
      @base = File.realpath(dir)
      # One directory every checkout writes to, standing in for a store two
      # machines share. Each clone would otherwise keep locks in its own .git.
      with_env("AGENT_LOCK_DIR" => File.join(base, "shared-store")) { example.run }
    end
  end

  let(:one) { checkout_at(File.join(base, "machine-one", "widgets")) }
  let(:two) { checkout_at(File.join(base, "machine-two", "src", "widgets")) }

  describe Agent::Lock::Tree do
    describe ".normalize_remote" do
      {
        "git@github.com:example/widgets.git" => "github.com/example/widgets",
        "https://github.com/example/widgets.git" => "github.com/example/widgets",
        "https://user@GitHub.com/example/widgets/" => "github.com/example/widgets",
        "ssh://git@github.com:22/example/widgets.git" => "github.com/example/widgets",
        "http://git.example.com:8418/team/widgets.git" => "git.example.com/team/widgets",
        "/srv/git/widgets.git" => "/srv/git/widgets"
      }.each do |url, expected|
        it "reads #{url} as #{expected}" do
          expect(described_class.normalize_remote(url)).to eq(expected)
        end
      end

      it "has nothing to say about no remote" do
        expect(described_class.normalize_remote(nil)).to be_nil
      end
    end

    it "names two checkouts at different paths as one repository" do
      expect(described_class.for(one).repo).to eq(described_class.for(two).repo)
    end

    it "keys them alike on one branch" do
      expect(described_class.for(one).lock_key).to eq("github.com/example/widgets@main")
    end

    it "falls back to the root commit when there is no origin" do
      bare = checkout_at(File.join(base, "no-origin"), origin: nil)

      expect(described_class.for(bare).repo).to eq(git(bare, "rev-list", "--max-parents=0", "HEAD"))
    end

    it "falls back to the path in a repository with nothing committed and no origin" do
      empty = checkout_at(File.join(base, "empty"), origin: nil, commit: false)

      expect(described_class.for(empty).repo).to eq(empty)
    end

    it "keys a detached HEAD by its own path, since it has no branch to share" do
      git(one, "checkout", "-q", "--detach")

      expect(described_class.for(one).lock_key).to eq(one)
    end
  end

  describe Agent::Lock::Manager do
    it "refuses a second checkout of the same branch the files the first one holds" do
      manager_in(one, "agent-one").acquire("lib/**", intent: "rewriting lib")

      outcome = manager_in(two, "agent-two").acquire("lib/a.rb", intent: "fixing a")

      aggregate_failures do
        expect(outcome.status).to eq(:held)
        expect(outcome.record.agent_id).to eq("agent-one")
      end
    end

    it "lets two checkouts on the same branch work on different files" do
      manager_in(one, "agent-one").acquire("lib/**", intent: "rewriting lib")

      expect(manager_in(two, "agent-two").acquire("docs/**", intent: "docs").status).to eq(:acquired)
    end

    it "leaves a checkout on another branch alone, the way a worktree should be" do
      manager_in(one, "agent-one").acquire("lib/**", intent: "rewriting lib")
      git(two, "checkout", "-q", "-b", "feature")

      expect(manager_in(two, "agent-two").acquire("lib/a.rb", intent: "fixing a").status).to eq(:acquired)
    end

    it "lets a session release its lock after switching branches" do
      manager_in(one, "agent-one").acquire("lib/**", intent: "rewriting lib")
      git(one, "checkout", "-q", "-b", "feature")

      expect(manager_in(one, "agent-one").release("lib/**").status).to eq(:released)
    end

    it "still blocks this checkout after it switches branches, since the files on disk are the same" do
      manager_in(one, "agent-one").acquire("lib/**", intent: "rewriting lib")
      git(one, "checkout", "-q", "-b", "feature")

      expect(manager_in(one, "agent-two").acquire("lib/a.rb", intent: "fixing a").status).to eq(:held)
    end

    it "respects a lock written before repo and branch were recorded, in its own checkout" do
      first = manager_in(one, "agent-one")
      first.acquire("lib/**", intent: "rewriting lib")
      rewrite = first.store.all.first.with(repo: nil, branch: nil)
      first.store.delete(first.store.all.first)
      first.store.create(rewrite)

      expect(manager_in(one, "agent-two").acquire("lib/a.rb", intent: "fixing a").status).to eq(:held)
    end

    it "does not thaw this checkout's files when it reaps a lock from another machine" do
      mine = manager_in(two, "agent-two")
      allow(Agent::Lock::Freeze).to receive(:clear)
      planted = Agent::Lock::Record.build(
        scope: Agent::Lock::Scope.parse("lib/**", tree: Agent::Lock::Tree.for(one)), tree: Agent::Lock::Tree.for(one),
        identity: Agent::Lock::Identity.new(env: { "AGENT_ID" => "agent-gone" }), intent: "elsewhere"
      ).with(host: "another-machine", frozen_paths: ["lib/a.rb"], created_at: "2000-01-01T00:00:00Z")
      mine.store.create(planted)

      reaped = mine.reap

      aggregate_failures do
        expect(reaped.map(&:agent_id)).to eq(["agent-gone"])
        expect(Agent::Lock::Freeze).not_to have_received(:clear)
      end
    end
  end

  describe Agent::Lock::Store::RedisStore do
    let(:redis) { Redis.new(url: RedisHelpers::TEST_REDIS_URL) }

    before { skip "no Redis on #{RedisHelpers::TEST_REDIS_URL}" unless redis_reachable?(RedisHelpers::TEST_REDIS_URL) }

    after { redis.flushdb if redis_reachable?(RedisHelpers::TEST_REDIS_URL) }

    it "gives every checkout of one repository the same namespace, so a lock taken in one is seen in the other" do
      trees = [one, two].map { |dir| Agent::Lock::Tree.for(dir) }
      stores = trees.map { |tree| described_class.new(tree, client: redis) }
      scope = Agent::Lock::Scope.parse("lib/**", tree: trees.first)
      identity = Agent::Lock::Identity.new(env: { "AGENT_ID" => "agent-one" })
      stores.first.create(Agent::Lock::Record.build(scope: scope, tree: trees.first, identity: identity, intent: "x"))

      aggregate_failures do
        expect(stores.map(&:mutex_key).uniq.size).to eq(1)
        expect(stores.last.find(scope)&.agent_id).to eq("agent-one")
      end
    end
  end
end

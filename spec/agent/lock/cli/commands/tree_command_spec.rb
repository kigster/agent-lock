# frozen_string_literal: true

# The store an `alock` call uses, when the caller names it instead of leaving
# it to whichever backend answers first: an agent started by a dispatcher has
# to land in the dispatcher's store, not in the one its own shell would pick.
#
# Pinned to no backend: every example names its own, whatever
# AGENT_LOCK_TEST_BACKEND says, so the Redis ones flush their own database.
RSpec.describe Agent::Lock::CLI::Commands::TreeCommand do
  include_context "a CLI"

  let(:url) { RedisHelpers::TEST_REDIS_URL }
  let(:marker) { expand_path(".git/agent-locks/backend") }
  let(:dead_url) { "redis://127.0.0.1:1/0" }

  before { delete_environment_variable("AGENT_LOCK_BACKEND") }

  after { Redis.new(url: url).flushdb if redis_reachable?(url) }

  describe "--locking-strategy" do
    it "claims a virgin tree for the file store, whatever Redis is doing" do
      command = agent_lock("acquire workflow --locking-strategy filesystem")

      expect([command.exit_status, File.read(marker).strip]).to eq([0, "file"])
    end

    it "takes file as another name for filesystem, and -s as the short flag" do
      agent_lock("acquire workflow -s file")

      expect(File.read(marker).strip).to eq("file")
    end

    it "wins over AGENT_LOCK_BACKEND" do
      set_environment_variable("AGENT_LOCK_BACKEND", "redis")
      agent_lock("acquire workflow -s filesystem")

      expect(File.read(marker).strip).to eq("file")
    end

    it "is refused with exit 2 in a tree whose locks live in the other store" do
      agent_lock("acquire workflow -s filesystem")

      command = agent_lock("list -s redis")

      expect([command.exit_status, command.stderr]).to match([2, /this tree's locks live in file, not redis/])
    end

    it "refuses a strategy that is not one, and names the two that are" do
      command = agent_lock("list -s carrier-pigeon")

      aggregate_failures do
        expect(command).to have_exit_status(2)
        expect(command.stderr).to include('unknown --locking-strategy "carrier-pigeon", expected redis or filesystem')
        expect(File.exist?(marker)).to be(false)
      end
    end
  end

  describe "--redis-url" do
    it "does not go with the file store" do
      command = agent_lock("list -s filesystem -u #{url}")

      expect([command.exit_status, command.stderr]).to match([2, /--redis-url does not go with/])
    end

    it "fails with exit 2 when nothing answers there, and leaves the tree unclaimed" do
      command = agent_lock("acquire workflow --redis-url #{dead_url}")

      aggregate_failures do
        expect(command).to have_exit_status(2)
        expect(command.stderr).to include("Redis did not answer on #{dead_url}")
        expect(File.exist?(marker)).to be(false)
      end
    end

    context "with a Redis that answers" do
      before { skip "no Redis on #{url}" unless redis_reachable?(url) }

      it "implies the redis strategy, and keeps the lock on that Redis" do
        command = agent_lock("acquire workflow 'installer' -u #{url}")

        aggregate_failures do
          expect(command.output).to include("ACQUIRED workflow/**")
          expect(File.read(marker).strip).to eq("redis")
          expect(Redis.new(url: url).keys("agent-lock:*").size).to eq(1)
        end
      end

      it "is where every other verb finds that lock" do
        agent_lock("acquire workflow 'installer' -u #{url}")

        aggregate_failures do
          expect(agent_lock("list -u #{url}").output).to include("workflow/**")
          expect(agent_lock("note workflow halfway -u #{url}")).to have_exit_status(0)
          expect(agent_lock("release workflow -u #{url}")).to have_exit_status(0)
          expect(Redis.new(url: url).keys("agent-lock:*")).to be_empty
        end
      end

      it "does not fall back to another Redis once the tree is claimed" do
        agent_lock("acquire workflow -u #{url}")

        expect(agent_lock("list -u #{dead_url}")).to have_exit_status(2)
      end
    end
  end
end

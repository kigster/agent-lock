# frozen_string_literal: true

require "tmpdir"

RSpec.describe Agent::Lock::Facade, type: :checkout do
  subject(:facade) { described_class.new(strategies: %w[file], agent_id: "luke-backend") }

  after { Agent::Lock.reset_facades! }

  describe "#backend_name" do
    its(:backend_name) { is_expected.to eq("file") }
  end

  describe ".new" do
    it "accepts filesystem as a name for the file store" do
      built = described_class.new(strategies: %w[filesystem])

      expect(built.backend_name).to eq("file")
    end

    it "uses the file store when redis is listed first and does not answer" do
      built = described_class.new(strategies: %w[redis file], redis_url: "redis://127.0.0.1:1")

      expect(built.backend_name).to eq("file")
    end

    it "does not try redis when file comes first" do
      built = described_class.new(strategies: %w[file redis], redis_url: "redis://127.0.0.1:1")

      expect(built.backend_name).to eq("file")
    end

    it "raises when redis is required and does not answer" do
      expect { described_class.new(strategies: %w[redis], redis_url: "redis://127.0.0.1:1") }
        .to raise_error(Agent::Lock::RedisUnavailableError, /127\.0\.0\.1:1/)
    end

    it "rejects an unknown strategy" do
      expect { described_class.new(strategies: %w[postgres]) }
        .to raise_error(ArgumentError, /postgres/)
    end

    it "rejects an empty strategy list" do
      expect { described_class.new(strategies: []) }.to raise_error(ArgumentError, /at least one/)
    end
  end

  describe "#acquire" do
    subject(:result) { facade.acquire("workflow/**", "rewriting the installer", dir: checkout) }

    its(:status) { is_expected.to eq(:acquired) }
    its("record.agent_id") { is_expected.to eq("luke-backend") }
    its("record.intent") { is_expected.to eq("rewriting the installer") }

    it "returns already_mine when this identity holds a covering scope" do
      facade.acquire("workflow/**", dir: checkout)

      expect(facade.acquire("workflow/lib/cli.rb", dir: checkout).status).to eq(:already_mine)
    end

    it "raises the command's stderr text when another agent holds the scope" do
      facade.acquire("workflow/**", "rewriting the installer", dir: checkout)

      expect { facade.acquire("workflow/lib/cli.rb", dir: checkout, agent_id: "rey-frontend") }
        .to raise_error(Agent::Lock::Refused, /REFUSED, do not write here/)
    end

    it "attaches the held record to the exception" do
      facade.acquire("workflow/**", dir: checkout, agent_id: "luke-backend")

      expect { facade.acquire("workflow/lib/cli.rb", dir: checkout, agent_id: "rey-frontend") }
        .to raise_error(Agent::Lock::Refused) { |error|
          expect(error.result.record.agent_id).to eq("luke-backend")
        }
    end

    it "raises when the scope is exactly the parent's claim" do
      facade.acquire("workflow/**", dir: checkout)
      child = described_class.new(strategies: %w[file], agent_id: "child", parent_id: "luke-backend")

      expect { child.acquire("workflow/**", dir: checkout) }
        .to raise_error(Agent::Lock::Refused, /parent's/)
    end

    it "lets the child claim a narrower scope inside that claim" do
      facade.acquire("workflow/**", dir: checkout)
      child = described_class.new(strategies: %w[file], agent_id: "child", parent_id: "luke-backend")

      expect(child.acquire("workflow/lib/cli.rb", dir: checkout).status).to eq(:acquired)
    end

    it "accepts a stale window for this call" do
      expect(facade.acquire("workflow/**", dir: checkout, stale_minutes: 5).status).to eq(:acquired)
    end

    it "raises when the scope still holds interrupted work" do
      facade.acquire("workflow/**", "half done", dir: checkout)
      facade.note("workflow/**", "stopped midway", dir: checkout)
      kill_holder(facade)

      expect { facade.acquire("workflow/**", dir: checkout, agent_id: "rey-frontend") }
        .to raise_error(Agent::Lock::Refused, /INTERRUPTED WORK/)
    end
  end

  describe "#release" do
    it "returns not_found when the scope is free" do
      expect(facade.release("workflow/**", dir: checkout).status).to eq(:not_found)
    end

    it "releases a lock this identity holds" do
      facade.acquire("workflow/**", dir: checkout)

      expect(facade.release("workflow/**", dir: checkout).status).to eq(:released)
    end

    it "raises when another agent holds the lock" do
      facade.acquire("workflow/**", dir: checkout)

      expect { facade.release("workflow/**", dir: checkout, agent_id: "rey-frontend") }
        .to raise_error(Agent::Lock::Refused, /not you/)
    end
  end

  describe "#check" do
    it "returns free when nobody holds the scope" do
      expect(facade.check("workflow/**", dir: checkout).status).to eq(:free)
    end

    it "returns mine when this identity holds it" do
      facade.acquire("workflow/**", dir: checkout)

      expect(facade.check("workflow/lib/cli.rb", dir: checkout).status).to eq(:mine)
    end

    it "raises when another agent holds it" do
      facade.acquire("workflow/**", dir: checkout)

      expect { facade.check("workflow/**", dir: checkout, agent_id: "rey-frontend") }
        .to raise_error(Agent::Lock::Refused, /HELD/)
    end
  end

  describe "#note" do
    it "raises when this identity holds nothing there" do
      expect { facade.note("workflow/**", "totals done", dir: checkout) }
        .to raise_error(Agent::Lock::Refused, /NOT LOCKED/)
    end

    it "records a note on a lock this identity holds" do
      facade.acquire("workflow/**", dir: checkout)

      expect(facade.note("workflow/**", "totals done", dir: checkout).status).to eq(:noted)
    end
  end

  describe "#list and #mine and #release_all" do
    before { facade.acquire("workflow/**", "billing", dir: checkout) }

    it "lists the lock" do
      expect(facade.list(dir: checkout).records.map(&:scope)).to include("workflow/**")
    end

    it "reports the lock as this identity's" do
      expect(facade.mine(dir: checkout).records.map(&:agent_id)).to eq(["luke-backend"])
    end

    it "releases every lock this identity holds" do
      result = facade.release_all(dir: checkout)

      expect(result.records.map(&:scope)).to eq(["workflow/**"])
      expect(facade.list(dir: checkout).records).to be_empty
    end
  end

  describe "#break_lock" do
    it "returns not_found when the scope is free" do
      expect(facade.break_lock("workflow/**", dir: checkout).status).to eq(:not_found)
    end

    it "returns the broken lock instead of raising" do
      facade.acquire("workflow/**", dir: checkout, agent_id: "rey-frontend")

      result = facade.break_lock("workflow/**", dir: checkout, agent_id: "luke-backend")

      expect(result.status).to eq(:broken)
    end
  end

  describe "#resume" do
    it "returns not_found when there is nothing to resume" do
      expect(facade.resume("workflow/**", dir: checkout).status).to eq(:not_found)
    end
  end

  describe "#whoami" do
    subject(:identity) { facade.whoami }

    its(:id) { is_expected.to eq("luke-backend") }
    its(:source) { is_expected.to eq(:explicit) }

    it "uses the agent id passed to the call" do
      expect(facade.whoami(agent_id: "rey-frontend").id).to eq("rey-frontend")
    end
  end

  describe "#version" do
    its(:version) { is_expected.to eq(Agent::Lock::VERSION) }
  end

  describe "#skills_path" do
    its(:skills_path) { is_expected.to end_with("skills/agent-lock") }
  end

  describe "#skills_install" do
    it "installs into the given directory and reports a second install as current" do
      Dir.mktmpdir("agent-lock-skills") do |dir|
        first = facade.skills_install(into: dir)
        second = facade.skills_install(into: dir)

        expect(first.status).to eq(:installed)
        expect(second.status).to eq(:current)
      end
    end

    it "keeps into when agent is also given" do
      Dir.mktmpdir("agent-lock-skills") do |dir|
        result = facade.skills_install(into: dir, agent: "claude")

        expect(result.status).to eq(:installed)
        expect(result.path).to start_with(dir)
      end
    end

    it "raises when the installed copy differs" do
      Dir.mktmpdir("agent-lock-skills") do |dir|
        facade.skills_install(into: dir)
        File.write(File.join(dir, "agent-lock", "SKILL.md"), "edited\n")

        expect { facade.skills_install(into: dir) }
          .to raise_error(Agent::Lock::Refused, /differs/)
      end
    end
  end

  describe "threads" do
    it "lets one of several callers acquire a scope and refuses the rest" do
      outcomes = Array.new(8) { |index| Thread.new { claim_as(index) } }.map(&:value)

      expect(outcomes.count(:acquired)).to eq(1)
      expect(outcomes.count(:refused)).to eq(7)
    end
  end

  describe "memoized facades" do
    it "returns the same local facade, and Facade.new does not replace it" do
      held = Agent::Lock.local
      described_class.new(strategies: %w[file])

      expect(Agent::Lock.local).to equal(held)
      expect(held.backend_name).to eq("file")
    end

    it "builds local once when several threads ask together" do
      barrier = Queue.new
      facades = Array.new(12) do
        Thread.new do
          barrier.pop
          Agent::Lock.local
        end
      end
      12.times { barrier << true }

      expect(facades.map(&:value).uniq.size).to eq(1)
    end

    it "raises again when distributed Redis still does not answer" do
      with_env("REDIS_URL" => "redis://127.0.0.1:1") do
        expect { Agent::Lock.distributed }.to raise_error(Agent::Lock::RedisUnavailableError)
        expect { Agent::Lock.distributed }.to raise_error(Agent::Lock::RedisUnavailableError)
      end
    end

    it "falls back to the file store from .facade when redis does not answer" do
      built = Agent::Lock.facade(redis_url: "redis://127.0.0.1:1")

      expect(built.backend_name).to eq("file")
      expect(built).not_to equal(Agent::Lock.local)
    end
  end

  def claim_as(index)
    facade.acquire("workflow/**", "thread #{index}", dir: checkout, agent_id: "agent-#{index}")
    :acquired
  rescue Agent::Lock::Refused
    :refused
  end

  def kill_holder(holder)
    pid = Process.spawn("true")
    Process.wait(pid)
    store = Agent::Lock::Store::FileSystemStore.new(tree)
    store.all.each { |record| store.update(record.with(pid: pid)) if record.agent_id == holder.whoami.id }
  end
end

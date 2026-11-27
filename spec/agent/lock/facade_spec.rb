# frozen_string_literal: true

require "tmpdir"

RSpec.describe Agent::Lock::Facade, type: :checkout do
  subject(:facade) { described_class.new(strategies: %w[file], agent_id: "luke-backend") }

  after { Agent::Lock.reset_facades! }

  describe "#backend_name" do
    its(:backend_name) { is_expected.to eq("file") }
  end

  describe ".new" do
    it { is_expected.to be_frozen }

    it "reads REDIS_URL when no redis_url is given" do
      with_env("REDIS_URL" => "redis://127.0.0.1:1") do
        expect(described_class.new(strategies: %w[file]).redis_url).to eq("redis://127.0.0.1:1")
      end
    end

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

    it "rejects a keyword no command takes, instead of ignoring it" do
      expect { facade.acquire("workflow/**", dir: checkout, force: true) }.to raise_error(ArgumentError, /force/)
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

    context "with a block" do
      it "yields the result, returns the block's value, and releases" do
        yielded = nil
        value = facade.acquire("workflow/**", "billing", dir: checkout) do |lock|
          yielded = lock.status
          :done
        end

        expect([value, yielded]).to eq(%i[done acquired])
        expect(facade.check("workflow/**", dir: checkout).status).to eq(:free)
      end

      it "releases when the block raises, then lets the exception out" do
        expect { facade.acquire("workflow/**", dir: checkout) { raise "boom" } }
          .to raise_error(RuntimeError, "boom")
        expect(facade.check("workflow/**", dir: checkout).status).to eq(:free)
      end

      it "does not enter the block when the acquire is refused" do
        facade.acquire("workflow/**", dir: checkout)
        yielded = false

        expect { facade.acquire("workflow/**", dir: checkout, agent_id: "rey-frontend") { yielded = true } }
          .to raise_error(Agent::Lock::Refused)
        expect(yielded).to be(false)
      end

      it "lets the block's own exception out when its lock was broken and retaken meanwhile" do
        expect do
          facade.acquire("workflow/**", dir: checkout) do
            facade.break_lock("workflow/**", dir: checkout)
            facade.acquire("workflow/**", dir: checkout, agent_id: "rey-frontend")
            raise ArgumentError, "the caller's own bug"
          end
        end.to raise_error(ArgumentError, "the caller's own bug")
      end

      it "raises the refused release when the block finished and its lock was retaken" do
        expect do
          facade.acquire("workflow/**", dir: checkout) do
            facade.break_lock("workflow/**", dir: checkout)
            facade.acquire("workflow/**", dir: checkout, agent_id: "rey-frontend")
          end
        end.to raise_error(Agent::Lock::Refused, /rey-frontend/)
      end

      it "releases when the block leaves by throw" do
        catch(:out) { facade.acquire("workflow/**", dir: checkout) { throw :out } }

        expect(facade.check("workflow/**", dir: checkout).status).to eq(:free)
      end

      it "leaves a lock this identity already held" do
        facade.acquire("workflow/**", dir: checkout)

        facade.acquire("workflow/lib/cli.rb", dir: checkout) { :inner }

        expect(facade.check("workflow/**", dir: checkout).status).to eq(:mine)
      end
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

    it "takes back interrupted work, notes and all" do
      facade.acquire("workflow/**", "half done", dir: checkout)
      facade.note("workflow/**", "stopped midway", dir: checkout)
      kill_holder(facade)

      result = facade.resume("workflow/**", dir: checkout, agent_id: "rey-frontend")

      expect([result.status, result.record.agent_id]).to eq([:resumed, "rey-frontend"])
    end
  end

  describe "the checkout's backend marker" do
    it "claims a new checkout for the facade's backend, so alock follows it" do
      facade.list(dir: checkout)

      expect(Agent::Lock::Store.recorded(tree)).to eq("file")
    end

    it "refuses a checkout already claimed for the other backend" do
      Agent::Lock::Store.claim(tree, "redis")

      expect { facade.acquire("workflow/**", dir: checkout) }
        .to raise_error(Agent::Lock::Store::Mismatch, /live in redis, but this facade uses file/)
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

    it "installs into the agent's own skills directory when only agent is given" do
      Dir.mktmpdir("agent-lock-home") do |home|
        with_env("HOME" => home) do
          expect(facade.skills_install(agent: "claude").path).to eq(File.join(home, ".claude", "skills", "agent-lock"))
        end
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

    # Each list reaps, so every thread rewrites the same orphaned record. A
    # temp file named after the pid alone was shared by all of them, and
    # every rename but the first raised Errno::ENOENT.
    it "lets many threads reap the same orphan at once without raising" do
      facade.acquire("workflow/**", "half done", dir: checkout)
      facade.note("workflow/**", "stopped midway", dir: checkout)
      kill_holder(facade)

      errors = in_threads(8, 10) { facade.list(dir: checkout) }

      expect(errors).to be_empty
    end

    it "lets many threads note one lock at once without raising" do
      facade.acquire("workflow/**", dir: checkout)

      errors = in_threads(8, 10) { |index| facade.note("workflow/**", "step #{index}", dir: checkout) }

      expect(errors).to be_empty
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

  # @return [Array<Exception>] whatever the block raised, across every thread
  def in_threads(threads, times)
    gate = Queue.new
    workers = Array.new(threads) do |index|
      Thread.new do
        gate.pop
        Array.new(times) do
          yield(index)
          nil
        rescue StandardError => e
          e
        end.compact
      end
    end
    threads.times { gate << true }
    workers.flat_map(&:value)
  end

  def kill_holder(holder)
    pid = Process.spawn("true")
    Process.wait(pid)
    store = Agent::Lock::Store::FileSystemStore.new(tree)
    store.all.each { |record| store.update(record.with(pid: pid)) if record.agent_id == holder.whoami.id }
  end
end

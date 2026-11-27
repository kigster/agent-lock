# frozen_string_literal: true

# What another session does to a lock while `acquire --enforce` is still
# walking the tree, outside the store's mutex. `Freeze.matches` is where the
# walk happens, so that is where the other session gets its turn.
RSpec.describe Agent::Lock::Manager::Enforcement, type: :checkout do
  let(:luke) { manager_for("luke-backend") }
  let(:rey) { manager_for("rey-frontend") }
  let(:frozen) { ["workflow/lib/cli.rb"] }

  before do
    allow(Agent::Lock::Freeze).to receive_messages(matches: frozen, apply: frozen)
    allow(Agent::Lock::Freeze).to receive(:clear)
  end

  def during_the_freeze
    allow(Agent::Lock::Freeze).to receive(:matches) do
      yield
      frozen
    end
  end

  def standing = luke.store.find(Agent::Lock::Scope.parse("workflow/**", tree: tree))

  it "writes the frozen paths into the lock" do
    result = luke.acquire("workflow/**", enforce: true)

    expect([result.status, standing.frozen_paths]).to eq([:acquired, frozen])
  end

  it "keeps a note written during the freeze" do
    during_the_freeze { luke.note("workflow/**", "halfway") }

    luke.acquire("workflow/**", enforce: true)

    expect([standing.intent, standing.frozen_paths]).to match([/halfway/, frozen])
  end

  context "when the lock is broken during the freeze" do
    before { during_the_freeze { rey.break_lock("workflow/**") } }

    it "does not bring the lock back, and says so" do
      result = luke.acquire("workflow/**", enforce: true)

      expect([result.status, result.records, standing]).to eq([:held, [], nil])
      expect(result.message).to include("broken while its files were being frozen")
    end

    it "thaws what it froze" do
      luke.acquire("workflow/**", enforce: true)

      expect(Agent::Lock::Freeze).to have_received(:clear).with(frozen, tree: anything)
    end
  end

  context "when somebody else takes the scope during the freeze" do
    before do
      during_the_freeze do
        rey.break_lock("workflow/**")
        rey.acquire("workflow/**", intent: "the newcomer")
      end
    end

    it "leaves the newcomer's lock alone and answers with it" do
      result = luke.acquire("workflow/**", enforce: true)

      expect([result.status, result.record.agent_id]).to eq([:held, "rey-frontend"])
      expect([standing.agent_id, standing.frozen_paths]).to eq(["rey-frontend", []])
    end

    it "leaves the newcomer's lock alone when the freeze is refused as too broad" do
      allow(Agent::Lock::Freeze).to receive(:apply).and_raise(Agent::Lock::Freeze::TooBroad, "too wide")

      expect { luke.acquire("workflow/**", enforce: true) }.to raise_error(Agent::Lock::Freeze::TooBroad)
      expect(standing.agent_id).to eq("rey-frontend")
    end

    it "leaves frozen the files the newcomer froze too" do
      during_the_freeze do
        rey.break_lock("workflow/**")
        rey.acquire("workflow/**")
        rey.store.update(standing.with(frozen_paths: frozen))
      end

      luke.acquire("workflow/**", enforce: true)

      expect(Agent::Lock::Freeze).not_to have_received(:clear).with(frozen, tree: anything)
    end
  end

  it "drops its own claim when the freeze is refused as too broad" do
    allow(Agent::Lock::Freeze).to receive(:apply).and_raise(Agent::Lock::Freeze::TooBroad, "too wide")

    expect { luke.acquire("workflow/**", enforce: true) }.to raise_error(Agent::Lock::Freeze::TooBroad)
    expect(standing).to be_nil
  end
end

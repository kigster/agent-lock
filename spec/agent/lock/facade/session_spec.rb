# frozen_string_literal: true

RSpec.describe Agent::Lock::Facade::Session, type: :checkout do
  subject(:session) { described_class.new(backend, agent_id: "luke-backend", stale_minutes: 7) }

  let(:backend) { Agent::Lock::Facade::Backend.new(strategies: %w[file], redis_url: "redis://127.0.0.1:1") }

  it { is_expected.to be_frozen }

  describe "#manager" do
    subject(:manager) { session.manager(dir: checkout) }

    its("identity.id") { is_expected.to eq("luke-backend") }
    its(:stale_minutes) { is_expected.to eq(7) }
    its(:store) { is_expected.to be_a(Agent::Lock::Store::FileSystemStore) }
    its("tree.root") { is_expected.to eq(tree.root) }

    it "lets a call override the defaults" do
      manager = session.manager(dir: checkout, agent_id: "rey-frontend", stale_minutes: 3)

      expect([manager.identity.id, manager.stale_minutes]).to eq(["rey-frontend", 3])
    end

    it "builds a new manager for every call" do
      expect(session.manager(dir: checkout)).not_to equal(session.manager(dir: checkout))
    end

    it "rejects a keyword it does not know" do
      expect { session.manager(dir: checkout, agent: "x") }.to raise_error(ArgumentError, /agent/)
    end
  end

  describe "#identity" do
    it "is Identity.current, read fresh, when nobody named the holder" do
      bare = described_class.new(backend)

      with_env("AGENT_ID" => "from-env") { expect(bare.identity.id).to eq("from-env") }
    end

    it "keeps the rest of the environment when it names the holder" do
      with_env("AGENT_PARENT_ID" => "orchestrator") do
        expect(session.identity.parent_id).to eq("orchestrator")
      end
    end

    it "names the parent passed to the call" do
      expect(session.identity(parent_id: "lead").parent_id).to eq("lead")
    end
  end
end

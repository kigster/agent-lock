# frozen_string_literal: true

RSpec.describe Agent::Lock::Identity do
  describe "where the name comes from" do
    it "takes AGENT_ID exactly as given, since a human set it on purpose" do
      expect(described_class.new(env: { "AGENT_ID" => "leah-researcher" }).id).to eq("leah-researcher")
    end

    it "falls back to the session, which survives a --resume" do
      identity = described_class.new(env: { "CLAUDE_SESSION_ID" => "01Tms9skZQfGQs4y" })

      expect(identity.id).to eq("session-01Tms9sk")
    end

    it "prefers AGENT_ID over the session when both are set" do
      identity = described_class.new(env: { "AGENT_ID" => "named", "CLAUDE_SESSION_ID" => "abcdefgh" })

      expect(identity.id).to eq("named")
    end
  end

  describe "the fingerprint, for a harness that exports neither" do
    subject(:identity) { described_class.new(env: {}) }

    # The bug this gem exists to fix: an agent runs each command in a shell of
    # its own, so an identity derived from this process cannot release what the
    # last one acquired.
    it "gives the same answer to two separate instances" do
      expect(identity.id).to eq(described_class.new(env: {}).id)
    end

    it "names the process it belongs to, so a human can recognise the holder" do
      expect(identity.id).to match(/\A[\w.-]+-[0-9a-f]{8}\z/)
    end

    it "carries the evidence a later run needs to ask whether it is still alive" do
      expect(identity.evidence).to include(:pid, :started, :host)
    end
  end

  describe "#source" do
    it "is explicit for AGENT_ID" do
      expect(described_class.new(env: { "AGENT_ID" => "named" }).source).to eq(:explicit)
    end

    it "is the session for CLAUDE_SESSION_ID alone" do
      expect(described_class.new(env: { "CLAUDE_SESSION_ID" => "abcdefgh" }).source).to eq(:session)
    end

    it "is the fingerprint when neither is set" do
      expect(described_class.new(env: {}).source).to eq(:fingerprint)
    end
  end

  describe "the parent" do
    subject(:identity) { described_class.new(env: env) }

    let(:fingerprint) { described_class.new(env: {}).id }

    context "when a harness declares it" do
      let(:env) { { "AGENT_ID" => "sub", "AGENT_PARENT_ID" => "parent" } }

      its(:parent_id) { is_expected.to eq("parent") }
      its(:parent_source) { is_expected.to eq(:explicit) }
    end

    # Claude Code runs a sub-agent inside its parent's process and tells it
    # nothing, so a sub-agent's one distinguishing mark is the AGENT_ID it
    # was told to use. The session it runs in is, by elimination, its parent.
    context "when a sub-agent names itself and nothing else" do
      let(:env) { { "AGENT_ID" => "sub" } }

      its(:parent_id) { is_expected.to eq(fingerprint) }
      its(:parent_source) { is_expected.to eq(:inferred) }
    end

    context "when the session a sub-agent runs in has a session id" do
      let(:env) { { "AGENT_ID" => "sub", "CLAUDE_SESSION_ID" => "01Tms9skZQfGQs4y" } }

      its(:parent_id) { is_expected.to eq("session-01Tms9sk") }
    end

    context "when AGENT_ID is the session's own fingerprint" do
      let(:env) { { "AGENT_ID" => fingerprint } }

      its(:parent_id) { is_expected.to be_nil }
      its(:parent_source) { is_expected.to be_nil }
    end

    context "when nothing is named at all" do
      let(:env) { {} }

      its(:parent_id) { is_expected.to be_nil }
      its(:parent_source) { is_expected.to be_nil }
    end
  end
end

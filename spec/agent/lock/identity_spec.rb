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

  it "reports the parent a sub-agent was spawned by" do
    identity = described_class.new(env: { "AGENT_ID" => "sub", "AGENT_PARENT_ID" => "parent" })

    expect(identity.parent_id).to eq("parent")
  end
end

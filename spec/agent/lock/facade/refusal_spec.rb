# frozen_string_literal: true

RSpec.describe Agent::Lock::Facade::Refusal do
  let(:record) do
    instance_double(Agent::Lock::Record, scope: "lib/**", agent_id: "luke-backend",
                                         created_at: "2026-11-25T10:00:00Z", intent: "billing")
  end

  def lock_result(status, records = [record])
    Agent::Lock::Manager::Result.new(status:, records:, message: nil)
  end

  def refusal_of(result, **)
    described_class.check!(result, **)
  rescue Agent::Lock::Refused => e
    e
  end

  it "returns a result that is not a refusal unchanged" do
    result = lock_result(:acquired)

    expect(described_class.check!(result)).to equal(result)
  end

  it "returns not_found unless the verb refuses it" do
    expect(described_class.check!(lock_result(:not_found, [])).status).to eq(:not_found)
  end

  it "raises not_found, naming the scope as typed, when the verb refuses it" do
    error = refusal_of(lock_result(:not_found, []), scope: "lib/x.rb", also: %i[not_found])

    expect(error.message).to eq("NOT LOCKED lib/x.rb, take the lock before writing in it")
  end

  it "names every holder of a held scope, with its intent" do
    error = refusal_of(lock_result(:held))

    expect(error.message).to eq("REFUSED, do not write here\n" \
                                "HELD  lib/**  by luke-backend  since 2026-11-25T10:00:00Z  intent: billing")
  end

  it "leaves the intent off a holder that gave none" do
    allow(record).to receive(:intent).and_return("")

    expect(refusal_of(lock_result(:held)).message).to end_with("since 2026-11-25T10:00:00Z")
  end

  it "names the scope as typed when interrupted work left no record to name" do
    error = refusal_of(lock_result(:interrupted, []), scope: "lib/**")

    expect(error.message).to eq("INTERRUPTED WORK on lib/**; resume it or break it")
  end

  it "carries the result it refused" do
    result = lock_result(:refused)

    expect(refusal_of(result).result).to equal(result)
  end

  {
    parent_scope: /your parent's \(luke-backend\) whole claim/,
    interrupted: %r{INTERRUPTED WORK on lib/\*\*, left by luke-backend},
    refused: %r{lib/\*\* is held by luke-backend, not you}
  }.each do |status, message|
    it "explains #{status}" do
      expect(refusal_of(lock_result(status)).message).to match(message)
    end
  end

  {
    differs: /differs from the copy this gem ships; pass overwrite: true/,
    linked: /is a symlink/
  }.each do |status, message|
    it "explains a skill install that #{status}" do
      result = Agent::Lock::Skill::Result.new(status:, path: "/tmp/skills/agent-lock")

      expect(refusal_of(result).message).to match(message)
    end
  end
end

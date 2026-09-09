# frozen_string_literal: true

RSpec.describe Agent::Lock do
  it "has a version number" do
    expect(Agent::Lock::VERSION).not_to be nil
  end
end

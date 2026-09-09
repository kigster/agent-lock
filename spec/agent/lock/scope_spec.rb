# frozen_string_literal: true

RSpec.describe Agent::Lock::Scope, type: :checkout do
  subject(:parse) { ->(text) { described_class.parse(text, tree: tree) } }

  describe "what a path means" do
    it "reads a directory as everything under it, since that is what working there means" do
      expect(parse["workflow"].pattern).to eq("workflow/**")
    end

    it "leaves a file alone" do
      expect(parse["workflow/lib/cli.rb"].pattern).to eq("workflow/lib/cli.rb")
    end

    it "takes an absolute path back to the tree it is in" do
      expect(parse[File.join(checkout, "workflow/lib/cli.rb")].pattern).to eq("workflow/lib/cli.rb")
    end

    it "reads an empty scope, a dot and a star as the whole tree" do
      expect([parse[""], parse["."], parse["**"]].map(&:pattern)).to all(eq("**"))
    end
  end

  describe "conflict" do
    it "sees a file inside a glob that covers it" do
      expect(parse["workflow/**"]).to be_conflicts_with(parse["workflow/lib/cli.rb"])
    end

    it "sees it from either side, since neither agent is privileged" do
      expect(parse["workflow/lib/cli.rb"]).to be_conflicts_with(parse["workflow/**"])
    end

    it "lets two corners of one tree work at once" do
      expect(parse["docs/**"]).not_to be_conflicts_with(parse["workflow/**"])
    end

    it "makes the whole tree conflict with everything, which is what ** is for" do
      expect(parse["**"]).to be_conflicts_with(parse["docs/api.md"])
    end

    it "treats two different files as no conflict at all" do
      expect(parse["a.rb"]).not_to be_conflicts_with(parse["b.rb"])
    end

    # Deliberate: guessing whether two globs can ever match the same path is a
    # question with wrong answers, and the wrong answer costs somebody's work.
    it "refuses rather than reasons when one glob's fixed part contains another's" do
      expect(parse["workflow/*.rb"]).to be_conflicts_with(parse["workflow/lib/**"])
    end
  end

  it "makes a filename-safe slug that still reads like the scope" do
    expect(parse["workflow/**"].slug).to eq("workflow-all")
  end
end

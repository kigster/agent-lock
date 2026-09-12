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

    it "reads a dot, a star and a double star as the whole tree" do
      expect([parse["."], parse["*"], parse["**"]].map(&:pattern)).to all(eq("**"))
    end

    it "reads the root, typed as a path, as the whole tree" do
      expect(parse[checkout].pattern).to eq("**")
    end

    it "reads a trailing slash and a leading dot the way they were meant" do
      expect([parse["workflow/"], parse["./workflow/**"]].map(&:pattern)).to all(eq("workflow/**"))
    end

    it "accepts a file that does not exist yet" do
      expect(parse["workflow/lib/new.rb"].pattern).to eq("workflow/lib/new.rb")
    end
  end

  describe "what it refuses" do
    it "raises an error the launcher already turns into exit 2" do
      expect(described_class::Invalid).to be < Agent::Lock::Error
    end

    # `alock acquire "$SCOPE"` with SCOPE unset used to claim the whole tree.
    it "refuses an empty scope rather than read it as the whole tree" do
      expect { parse[""] }
        .to raise_error(described_class::Invalid, "empty scope: pass ** to claim the whole tree")
    end

    it "refuses a blank or missing scope the same way" do
      [" \t", nil].each do |text|
        expect { parse[text] }.to raise_error(described_class::Invalid, /empty scope/)
      end
    end

    it "refuses a path outside the tree instead of locking a tree file with the same basename" do
      expect { parse["/etc/passwd"] }
        .to raise_error(described_class::Invalid, "/etc/passwd is outside the tree #{checkout}")
    end
  end

  describe "a glob" do
    it "is taken back to the tree when it is spelled absolutely, so it meets its relative twin" do
      scope = parse[File.join(checkout, "workflow/**")]

      expect(scope.pattern).to eq("workflow/**")
      expect(scope).to be_conflicts_with(parse["workflow/lib/cli.rb"])
    end

    it "keeps a wildcard in the middle, relativising only the part before it" do
      expect(parse[File.join(checkout, "workflow/*/cli.rb")].pattern).to eq("workflow/*/cli.rb")
    end

    it "is left alone when it starts with a wildcard" do
      expect(parse["**/*.rb"].pattern).to eq("**/*.rb")
    end

    it "is read from where the agent stands, like a plain path" do
      scope = described_class.parse("lib/*.rb", tree: Agent::Lock::Tree.for(File.join(checkout, "workflow")))

      expect(scope.pattern).to eq("workflow/lib/*.rb")
    end

    it "is refused when it climbs out of the tree" do
      expect { parse["../outside/**"] }.to raise_error(described_class::Invalid, /outside the tree #{checkout}/)
    end

    it "is refused when it is spelled absolutely somewhere else" do
      expect { parse["/**"] }.to raise_error(described_class::Invalid, /outside the tree/)
    end

    it "is refused when it lives in a sibling that shares the root's name as a prefix" do
      expect { parse["#{checkout}-other/**"] }.to raise_error(described_class::Invalid, /outside the tree/)
    end

    # Nothing can say where `*/..` lands without expanding the wildcard, and the
    # fixed part it was checked against no longer bounds it.
    it "is refused when a .. follows a wildcard" do
      expect { parse["workflow/*/../../../etc/**"] }.to raise_error(described_class::Invalid, /after a wildcard/)
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

  # Overlapping is not the same as covering. An agent holding one file that
  # asks for the whole tree has not got the whole tree.
  describe "cover" do
    it "covers everything under a directory glob" do
      expect(parse["workflow/**"]).to be_covers(parse["workflow/lib/cli.rb"])
    end

    it "covers everything from the whole tree" do
      expect(parse["**"]).to be_covers(parse["docs/**"])
    end

    it "covers itself" do
      expect(parse["workflow/*.rb"]).to be_covers(parse["workflow/*.rb"])
    end

    it "does not cover a wider scope, however much the two overlap" do
      expect(parse["workflow/lib/cli.rb"]).not_to be_covers(parse["workflow/**"])
    end

    it "does not guess what a partial glob covers" do
      expect(parse["workflow/*.rb"]).not_to be_covers(parse["workflow/cli.rb"])
    end

    it "does not cover a glob that can reach outside its directory" do
      expect(parse["workflow/**"]).not_to be_covers(parse["**/cli.rb"])
    end
  end

  it "makes a filename-safe slug that still reads like the scope" do
    expect(parse["workflow/**"].slug).to eq("workflow-all")
  end
end

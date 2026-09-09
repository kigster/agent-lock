# frozen_string_literal: true

RSpec.describe Agent::Lock::Manager, type: :checkout do
  subject(:luke) { manager_for("luke-backend") }

  let(:rey) { manager_for("rey-frontend") }

  describe "#acquire" do
    it "claims a free scope" do
      result = luke.acquire("workflow/**", intent: "rewriting the installer")

      aggregate_failures do
        expect(result.status).to eq(:acquired)
        expect(result.code).to eq(0)
        expect(result.record.intent).to eq("rewriting the installer")
      end
    end

    it "refuses another session's overlapping scope, and says who has it" do
      luke.acquire("workflow/**", intent: "rewriting the installer")

      result = rey.acquire("workflow/lib/cli.rb")

      aggregate_failures do
        expect(result.status).to eq(:held)
        expect(result.code).to eq(1)
        expect(result.record.agent_id).to eq("luke-backend")
        expect(result.record.intent).to eq("rewriting the installer")
      end
    end

    it "lets two sessions work in two corners of one tree" do
      luke.acquire("workflow/**")

      expect(rey.acquire("docs/**").status).to eq(:acquired)
    end

    it "is re-entrant, so the same session asking twice is not a conflict" do
      luke.acquire("workflow/**")

      expect(luke.acquire("workflow/**").status).to eq(:already_mine)
    end

    # A sub-agent is not a second agent. It works inside its parent's claim,
    # and refusing it would make parallel work impossible for the one harness
    # that most needs it.
    it "lets a sub-agent write inside its parent's lock" do
      luke.acquire("workflow/**")
      sub = manager_for("subagent-4f2a", parent: "luke-backend")

      expect(sub.acquire("workflow/lib/cli.rb").status).to eq(:already_mine).or eq(:acquired)
    end
  end

  describe "#release" do
    it "gives a scope back to whoever wants it next" do
      luke.acquire("workflow/**")

      aggregate_failures do
        expect(luke.release("workflow/**").status).to eq(:released)
        expect(rey.acquire("workflow/**").status).to eq(:acquired)
      end
    end

    it "refuses to release a lock another session holds" do
      luke.acquire("workflow/**")

      result = rey.release("workflow/**")

      aggregate_failures do
        expect(result.status).to eq(:refused)
        expect(result.code).to eq(1)
      end
    end

    it "says so plainly when there was nothing to release" do
      expect(luke.release("workflow/**").status).to eq(:not_found)
    end
  end

  describe "#check" do
    it "is free when nothing overlaps" do
      expect(luke.check("workflow/**").status).to eq(:free)
    end

    it "exits non-zero when something does, so a shell script can gate on it" do
      rey.acquire("workflow/**")

      expect(luke.check("workflow/lib/cli.rb").code).to eq(1)
    end
  end

  describe "#mine and #release_all" do
    it "sees only this session's locks, and drops them all at once" do
      luke.acquire("workflow/**")
      luke.acquire("docs/**")
      rey.acquire("spec/**")

      aggregate_failures do
        expect(luke.mine.records.map(&:scope)).to contain_exactly("workflow/**", "docs/**")
        expect(luke.release_all.records.size).to eq(2)
        expect(luke.mine.records).to be_empty
        expect(rey.mine.records.map(&:scope)).to eq(["spec/**"])
      end
    end
  end

  describe "#break_lock" do
    it "takes a live lock away from its holder" do
      rey.acquire("workflow/**")

      aggregate_failures do
        expect(luke.break_lock("workflow/**").status).to eq(:broken)
        expect(luke.acquire("workflow/**").status).to eq(:acquired)
      end
    end
  end

  describe "reaping" do
    # The case that matters: a session killed mid-run leaves a lock nobody can
    # release, and the next agent has to be able to tell that from a lock whose
    # holder is still working.
    it "clears a lock whose holder is long gone and nobody has touched" do
      rey.acquire("workflow/**")
      impatient = manager_for("luke-backend", stale_minutes: 0)

      aggregate_failures do
        expect(impatient.reap.map(&:scope)).to eq(["workflow/**"])
        expect(impatient.acquire("workflow/**").status).to eq(:acquired)
      end
    end

    it "leaves a fresh lock alone" do
      rey.acquire("workflow/**")

      expect(luke.reap).to be_empty
    end
  end

  describe "the store the locks live in" do
    it "hides inside .git, where no repository has to ignore them" do
      expect(tree.store_dir).to eq(File.join(checkout, ".git", "agent-locks"))
    end

    it "writes a lock a person can read" do
      luke.acquire("workflow/**", intent: "rewriting the installer")

      text = Dir[File.join(tree.store_dir, "*.lock.md")].map { |f| File.read(f) }.first

      aggregate_failures do
        expect(text).to include("agent_id: luke-backend")
        expect(text).to include("rewriting the installer")
      end
    end
  end
end
RSpec.describe "surviving a restart", type: :checkout do
  subject(:luke) { manager_for("luke-backend") }

  let(:impatient) { manager_for("rey-frontend", stale_minutes: 0) }

  it "keeps the notes of a session that died, rather than reaping them" do
    luke.acquire("workflow/**", intent: "rewriting the installer")
    luke.note("workflow/**", "installer rewritten, specs still red")

    impatient.reap
    record = Agent::Lock::Manager.new(tree: tree, identity: luke.identity).list.record

    aggregate_failures do
      expect(record).to be_orphaned
      expect(record.intent).to include("installer rewritten, specs still red")
    end
  end

  it "deletes a lock that recorded nothing, since there is nothing to come back to" do
    luke.acquire("workflow/**", intent: "rewriting the installer")

    impatient.reap

    expect(impatient.list.records).to be_empty
  end

  it "points the next agent at the interrupted work rather than overwriting it" do
    luke.acquire("workflow/**")
    luke.note("workflow/**", "halfway")
    impatient.reap

    result = impatient.acquire("workflow/**")

    aggregate_failures do
      expect(result.status).to eq(:interrupted)
      expect(result.record.intent).to include("halfway")
    end
  end

  # An orphan is a note somebody left, not a claim they still have. It says
  # what happened in the corner it names, and nothing about the rest of the
  # tree.
  it "does not block work elsewhere in the tree" do
    luke.acquire("workflow/**")
    luke.note("workflow/**", "halfway")
    impatient.reap

    expect(impatient.acquire("docs/**").status).to eq(:acquired)
  end

  it "can be thrown away by whoever decides it is not worth resuming" do
    luke.acquire("workflow/**")
    luke.note("workflow/**", "halfway")
    impatient.reap
    impatient.break_lock("workflow/**")

    expect(impatient.acquire("workflow/**").status).to eq(:acquired)
  end

  it "hands the work back, notes and all, to whoever resumes it" do
    luke.acquire("workflow/**", intent: "rewriting the installer")
    luke.note("workflow/**", "installer rewritten, specs still red")
    impatient.reap

    # A new session: after a reboot the pid is different and so is the
    # fingerprint, so resuming cannot depend on being recognised.
    returning = manager_for("luke-backend-after-reboot")
    result = returning.resume("workflow/**")

    aggregate_failures do
      expect(result.status).to eq(:resumed)
      expect(result.record.agent_id).to eq("luke-backend-after-reboot")
      expect(result.record.intent).to include("specs still red")
      expect(returning.check("workflow/lib/cli.rb").status).to eq(:mine)
    end
  end

  it "refuses to write notes into somebody else's lock" do
    luke.acquire("workflow/**")

    expect(manager_for("rey-frontend").note("workflow/**", "sneaking in").status).to eq(:refused)
  end
end

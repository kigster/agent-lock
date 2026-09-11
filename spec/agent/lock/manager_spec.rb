# frozen_string_literal: true

# Things that happen to a holder after it took a lock, done to the lock in the
# real store rather than by stubbing the clock or the process table, which
# would test the stub.
module HolderHistory
  # @param manager [Agent::Lock::Manager] whose locks to rewrite
  # @yieldparam record [Agent::Lock::Record]
  # @yieldreturn [Agent::Lock::Record] what to store in its place
  def rewrite(manager)
    manager.store.all.select { |record| record.agent_id == manager.identity.id }.each do |record|
      manager.store.update(yield(record))
    end
  end

  # Every manager in one spec run shares the test process's session pid, so
  # killing one holder means pointing its locks at a process that has exited.
  #
  # @param manager [Agent::Lock::Manager]
  def kill(manager)
    pid = Process.spawn("true")
    Process.wait(pid)
    rewrite(manager) { |record| record.with(pid: pid) }
  end
end

RSpec.describe Agent::Lock::Manager, type: :checkout do
  include HolderHistory

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

    # A sub-agent works inside its parent's claim, and refusing it would make
    # parallel work impossible for the one harness that most needs it. It
    # still records a claim of its own, or its siblings could not see it.
    it "lets a sub-agent claim inside its parent's lock" do
      luke.acquire("workflow/**")
      sub = manager_for("subagent-4f2a", parent: "luke-backend")

      expect(sub.acquire("workflow/lib/cli.rb").status).to eq(:acquired)
    end

    it "takes the store's mutex for the scan and the write, and freezes outside it" do
      inside = false
      frozen_inside = nil
      allow(luke.store).to receive(:synchronize).and_wrap_original do |original, &block|
        original.call do
          inside = true
          block.call
        ensure
          inside = false
        end
      end
      allow(Agent::Lock::Freeze).to receive(:apply) do
        frozen_inside = inside
        []
      end

      result = luke.acquire("workflow/**", enforce: true)

      aggregate_failures do
        expect(result.status).to eq(:acquired)
        expect(luke.store).to have_received(:synchronize).once
        expect(frozen_inside).to be(false)
      end
    end
  end

  # The documented orchestration pattern: a parent claims an umbrella and
  # fans out, each sub-agent claims its own corner inside it. Before this
  # worked, a child's claim inside its parent's lock recorded nothing, so two
  # siblings both "acquired" one file, and a child's release-all took its
  # parent's umbrella with it.
  describe "a family working in one tree" do
    let(:orchestrator) { manager_for("orchestrator") }
    let(:alpha) { manager_for("alpha", parent: "orchestrator") }
    let(:beta) { manager_for("beta", parent: "orchestrator") }
    let(:file) { "workflow/lib/cli.rb" }

    before { orchestrator.acquire("workflow/**", intent: "fanning out") }

    it "records a child's claim under the child's own name" do
      result = alpha.acquire(file, intent: "the CLI")

      aggregate_failures do
        expect(result.status).to eq(:acquired)
        expect(result.record.agent_id).to eq("alpha")
        expect(result.record.parent_agent_id).to eq("orchestrator")
      end
    end

    it "refuses a sibling the file its sibling claimed" do
      alpha.acquire(file, intent: "the CLI")

      result = beta.acquire(file)

      aggregate_failures do
        expect(result.status).to eq(:held)
        expect(result.code).to eq(1)
        expect(result.record.agent_id).to eq("alpha")
      end
    end

    it "is re-entrant for the child's own claim" do
      alpha.acquire(file)

      expect(alpha.acquire(file).status).to eq(:already_mine)
    end

    # Records are keyed by tree and scope, so the child cannot hold a second
    # record on the one its parent holds. Letting it through with nothing
    # written down is the bug; refusing fails closed.
    it "refuses a child its parent's exact scope, and names the parent" do
      result = alpha.acquire("workflow/**")

      aggregate_failures do
        expect(result.status).to eq(:parent_scope)
        expect(result.code).to eq(1)
        expect(result.records.map(&:agent_id)).to eq(["orchestrator"])
      end
    end

    it "leaves the parent's lock standing after a child's release-all" do
      alpha.acquire(file)

      aggregate_failures do
        expect(alpha.release_all.records.map(&:agent_id)).to eq(["alpha"])
        expect(orchestrator.mine.records.map(&:scope)).to eq(["workflow/**"])
      end
    end

    it "does not count the parent's lock among the child's" do
      aggregate_failures do
        expect(alpha.mine.records).to be_empty
        expect(alpha.release("workflow/**").status).to eq(:refused)
        expect(alpha.note("workflow/**", "not mine to write in").status).to eq(:refused)
      end
    end

    it "tells a child it is free to claim inside its parent's lock" do
      expect(alpha.check(file).status).to eq(:free)
    end

    it "still lets the parent sweep up after its children" do
      alpha.acquire(file)

      expect(orchestrator.release_all.records.map(&:agent_id)).to contain_exactly("orchestrator", "alpha")
    end

    # What a Claude Code sub-agent actually has: its own AGENT_ID and the
    # parent's process. No AGENT_PARENT_ID, since nothing sets one.
    context "when the parent is the session's fingerprint and the children only name themselves" do
      let(:orchestrator) { Agent::Lock::Manager.new(tree: tree, identity: Agent::Lock::Identity.new(env: {})) }
      let(:alpha) { manager_for("alpha") }
      let(:beta) { manager_for("beta") }

      it "keeps the siblings apart all the same" do
        aggregate_failures do
          expect(alpha.acquire(file).status).to eq(:acquired)
          expect(beta.acquire(file).status).to eq(:held)
          expect(alpha.release_all.records.map(&:agent_id)).to eq(["alpha"])
          expect(orchestrator.mine.records.map(&:scope)).to eq(["workflow/**"])
        end
      end
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
    let(:three_hours_ago) { (Time.now.utc - (3 * 3600)).iso8601 }

    # The case that matters: a session killed mid-run leaves a lock nobody can
    # release, and the next agent has to be able to tell that from a lock whose
    # holder is still working.
    it "clears a lock whose holder is gone" do
      rey.acquire("workflow/**")
      kill(rey)

      aggregate_failures do
        expect(luke.reap.map(&:scope)).to eq(["workflow/**"])
        expect(luke.acquire("workflow/**").status).to eq(:acquired)
      end
    end

    it "leaves a fresh lock alone" do
      rey.acquire("workflow/**")

      expect(luke.reap).to be_empty
    end

    # A long refactor is not a crash. Reaping by age used to take the lock
    # from under a session still working in there, and the next agent walked
    # straight in. Age is reported instead, and breaking it stays a decision
    # somebody announces.
    it "never reaps a live holder's lock, however old, but reports it stale" do
      rey.acquire("workflow/**")
      rewrite(rey) { |record| record.with(created_at: three_hours_ago) }

      aggregate_failures do
        expect(luke.reap).to be_empty
        expect(luke.acquire("workflow/lib/cli.rb").status).to eq(:held)
        expect(luke.list.record.stale?(luke.stale_minutes)).to be(true)
      end
    end

    # A lock written on another machine, through a synced or shared store,
    # has a holder nobody here can ask about. Time is all there is, measured
    # from the last thing it wrote, so its notes keep it alive.
    context "when the holder is on another host" do
      before do
        rey.acquire("workflow/**")
        rewrite(rey) { |record| record.with(host: "elsewhere.example", created_at: three_hours_ago) }
      end

      it "expires once nobody has touched it for longer than the window" do
        expect(luke.reap.map(&:scope)).to eq(["workflow/**"])
      end

      it "does not expire while its holder keeps writing notes" do
        rey.note("workflow/**", "still going")

        aggregate_failures do
          expect(luke.reap).to be_empty
          expect(luke.acquire("workflow/lib/cli.rb").status).to eq(:held)
        end
      end
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

  # `.plans`, `.github`, `.circleci` and the rest are ordinary places for an
  # agent to work, and a scope named after one produces a lock file whose name
  # also starts with a dot. `Dir.glob` skips those unless it is told not to,
  # which used to leave the lock written, invisible, and enforcing nothing.
  describe "a scope that starts with a dot" do
    before { FileUtils.mkdir_p(File.join(checkout, ".plans", "037")) }

    it "is visible to the session holding it" do
      luke.acquire(".plans/**", intent: "writing the spec")

      expect(luke.mine.records.map(&:scope)).to eq([".plans/**"])
    end

    it "refuses another session an overlapping scope inside it" do
      luke.acquire(".plans/**", intent: "writing the spec")

      result = rey.acquire(".plans/037/spec.md")

      aggregate_failures do
        expect(result.status).to eq(:held)
        expect(result.record.agent_id).to eq("luke-backend")
      end
    end

    it "answers #check like any other scope" do
      luke.acquire(".plans/**")

      expect(rey.check(".plans/037/spec.md").code).to eq(1)
    end

    it "goes away with #release_all" do
      luke.acquire(".plans/**")

      aggregate_failures do
        expect(luke.release_all.records.size).to eq(1)
        expect(rey.acquire(".plans/**").status).to eq(:acquired)
      end
    end
  end
end

RSpec.describe "surviving a restart", type: :checkout do
  include HolderHistory

  subject(:luke) { manager_for("luke-backend") }

  # Death, not age, is what reaps a lock on this host. Luke dies in each
  # example before anybody looks.
  let(:successor) { manager_for("rey-frontend") }

  it "keeps the notes of a session that died, rather than reaping them" do
    luke.acquire("workflow/**", intent: "rewriting the installer")
    luke.note("workflow/**", "installer rewritten, specs still red")

    kill(luke)
    successor.reap
    record = Agent::Lock::Manager.new(tree: tree, identity: luke.identity).list.record

    aggregate_failures do
      expect(record).to be_orphaned
      expect(record.intent).to include("installer rewritten, specs still red")
    end
  end

  it "deletes a lock that recorded nothing, since there is nothing to come back to" do
    luke.acquire("workflow/**", intent: "rewriting the installer")

    kill(luke)
    successor.reap

    expect(successor.list.records).to be_empty
  end

  it "points the next agent at the interrupted work rather than overwriting it" do
    luke.acquire("workflow/**")
    luke.note("workflow/**", "halfway")
    kill(luke)
    successor.reap

    result = successor.acquire("workflow/**")

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
    kill(luke)
    successor.reap

    expect(successor.acquire("docs/**").status).to eq(:acquired)
  end

  it "can be thrown away by whoever decides it is not worth resuming" do
    luke.acquire("workflow/**")
    luke.note("workflow/**", "halfway")
    kill(luke)
    successor.reap
    successor.break_lock("workflow/**")

    expect(successor.acquire("workflow/**").status).to eq(:acquired)
  end

  it "hands the work back, notes and all, to whoever resumes it" do
    luke.acquire("workflow/**", intent: "rewriting the installer")
    luke.note("workflow/**", "installer rewritten, specs still red")
    kill(luke)
    successor.reap

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

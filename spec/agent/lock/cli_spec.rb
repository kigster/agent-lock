# frozen_string_literal: true

# The CLI end to end, in this process. Every exit code here is the one a shell
# would see, which is the half of a CLI's contract that is easiest to break and
# hardest to notice.
RSpec.describe Agent::Lock::CLI do
  include_context "a CLI"

  # A lock written straight into the store, for the states one CLI session
  # cannot reach inside an example: a holder that crashed, or one that has
  # been quiet for hours. The holder evidence is this process's, so the
  # holder is alive unless the status says otherwise.
  #
  # @param scope [String]
  # @param agent [String] the holder's id
  # @param status [String] Record::ACTIVE or Record::ORPHANED
  # @param age [Integer] seconds since the lock was taken, and last touched
  # @return [Agent::Lock::Record]
  def plant(scope, agent:, status: Agent::Lock::Record::ACTIVE, age: 0)
    cd(".") do
      tree = Agent::Lock::Tree.for
      identity = Agent::Lock::Identity.new(env: { "AGENT_ID" => agent })
      record = Agent::Lock::Record.build(
        scope: Agent::Lock::Scope.parse(scope, tree: tree), tree: tree, identity: identity, intent: "planted"
      )
      record = record.note("got halfway") if status == Agent::Lock::Record::ORPHANED
      taken = (Time.now.utc - age).iso8601
      record.with(status: status, created_at: taken, updated_at: taken).tap do |planted|
        Agent::Lock::Store.for(tree).create(planted)
      end
    end
  end

  describe "acquire" do
    it "claims a scope and exits 0" do
      command = agent_lock("acquire workflow 'rewriting the installer'")

      aggregate_failures do
        expect(command).to have_exit_status(0)
        expect(command.output).to include("ACQUIRED workflow/**")
      end
    end

    it "refuses another session's scope with exit 1, and says what they are doing" do
      agent_lock("acquire workflow 'rewriting the installer'")
      set_environment_variable("AGENT_ID", "somebody-else")

      command = agent_lock("acquire workflow/lib/cli.rb")

      aggregate_failures do
        expect(command).to have_exit_status(1)
        expect(command.output).to include("REFUSED")
        expect(command.output).to include("intent: rewriting the installer")
      end
    end

    # Records are keyed by tree and scope, so the child's lock would have to
    # be the parent's own record. Refusing is the only answer that fails
    # closed, and the child needs telling what to do instead.
    it "refuses a sub-agent its parent's whole claim, and tells it to narrow" do
      set_environment_variable("AGENT_ID", "boss-agent")
      agent_lock("acquire workflow 'fanning out'")
      set_environment_variable("AGENT_ID", "kid-agent")
      set_environment_variable("AGENT_PARENT_ID", "boss-agent")

      command = agent_lock("acquire workflow")

      aggregate_failures do
        expect(command).to have_exit_status(1)
        expect(command.stderr).to include(
          "REFUSED: workflow/** is your parent's (boss-agent) whole claim; claim a narrower scope inside it"
        )
        expect(command.stdout).to be_empty
      end
    end
  end

  # A sub-agent cannot be told apart from its parent by anything but the
  # AGENT_ID it was given, so it needs a way to see what it will be taken for
  # before its first lock goes down under the wrong name.
  describe "whoami" do
    before do
      delete_environment_variable("AGENT_PARENT_ID")
      delete_environment_variable("CLAUDE_SESSION_ID")
    end

    let(:session_id) { Agent::Lock::Identity.new(env: {}).id }

    it "says who this is, who its parent is, and where each came from" do
      set_environment_variable("AGENT_ID", "kid-agent")
      set_environment_variable("AGENT_PARENT_ID", "boss-agent")

      command = agent_lock("whoami")

      aggregate_failures do
        expect(command).to have_exit_status(0)
        expect(command.stdout).to match(/^id:\s+kid-agent\s+\(from AGENT_ID\)$/)
        expect(command.stdout).to match(/^parent:\s+boss-agent\s+\(from AGENT_PARENT_ID\)$/)
      end
    end

    it "names the session as the parent it inferred" do
      set_environment_variable("AGENT_ID", "kid-agent")

      command = agent_lock("whoami")

      expect(command.stdout).to match(/^parent:\s+#{Regexp.escape(session_id)}\s+\(inferred/)
    end

    it "answers in JSON for whoever is parsing it" do
      set_environment_variable("AGENT_ID", "kid-agent")

      parsed = JSON.parse(agent_lock("whoami --json").stdout)

      expect(parsed).to eq(
        "id" => "kid-agent", "source" => "explicit", "parent_id" => session_id, "parent_source" => "inferred"
      )
    end

    # The failure this whole command exists for: every sub-agent of one
    # session, unnamed, resolves to this same id and none can block another.
    it "warns a session with no name of its own that its sub-agents share it" do
      delete_environment_variable("AGENT_ID")

      command = agent_lock("whoami")

      aggregate_failures do
        expect(command).to have_exit_status(0)
        expect(command.stdout).to match(/^id:\s+#{Regexp.escape(session_id)}\s+\(from the process fingerprint\)$/)
        expect(command.stdout).to match(/^parent:\s+none$/)
        expect(command.stderr).to include("AGENT_ID=<name> agent-lock")
      end
    end
  end

  describe "release" do
    it "releases what this session took, in a separate invocation" do
      agent_lock("acquire workflow 'one'")

      command = agent_lock("release workflow")

      aggregate_failures do
        expect(command).to have_exit_status(0)
        expect(command.output).to include("RELEASED workflow/**")
      end
    end
  end

  describe "check" do
    it "exits 0 and says free when nothing holds it" do
      command = agent_lock("check workflow")

      aggregate_failures do
        expect(command).to have_exit_status(0)
        expect(command.output).to include("FREE")
      end
    end

    it "exits 1 when something does" do
      agent_lock("acquire workflow 'one'")
      set_environment_variable("AGENT_ID", "somebody-else")

      expect(agent_lock("check workflow/lib/cli.rb")).to have_exit_status(1)
    end

    it "answers in JSON for whoever is parsing it" do
      agent_lock("acquire workflow 'one'")
      set_environment_variable("AGENT_ID", "somebody-else")

      command = agent_lock("check workflow --json")
      parsed = JSON.parse(command.output)

      expect(parsed.first).to include("scope" => "workflow/**", "intent" => "one", "stale" => false)
    end

    # The one refused is the one who needs to know the holder has gone
    # quiet: it is the difference between waiting and asking a human.
    it "tags a claim nobody has touched in hours STALE" do
      plant("workflow/**", agent: "slow-agent", age: 3 * 3600)

      command = agent_lock("check workflow/lib/cli.rb")

      aggregate_failures do
        expect(command).to have_exit_status(1)
        expect(command.stderr).to match(%r{^HELD  workflow/\*\*  by slow-agent .*STALE$})
        expect(command.stderr).to include("agent-lock break")
      end
    end

    it "tells the holder that a scope is theirs rather than that it is free" do
      agent_lock("acquire workflow 'one'")

      command = agent_lock("check workflow/lib/cli.rb")

      aggregate_failures do
        expect(command).to have_exit_status(0)
        expect(command.output).to include("YOURS workflow/**")
      end
    end
  end

  describe "list, mine and release-all" do
    it "lists what is held, and drops it" do
      agent_lock("acquire workflow 'one'")
      agent_lock("acquire docs 'two'")

      aggregate_failures do
        expect(agent_lock("list").output).to include("Locks held (2)")
        expect(agent_lock("mine").output).to include("workflow/**")
        expect(agent_lock("release-all").output).to include("Released 2 lock(s)")
        expect(agent_lock("list").output).to include("No locks held")
      end
    end

    # An orphan is a note left for whoever comes next, not a claim: it blocks
    # nobody. Counting it as held told a reader the tree was busier than it
    # was, and gave them no way to tell which locks were real.
    it "counts only live claims as held, and lists interrupted work on its own" do
      agent_lock("acquire workflow 'one'")
      plant("docs/**", agent: "crashed-agent", status: Agent::Lock::Record::ORPHANED)

      command = agent_lock("list")

      aggregate_failures do
        expect(command.stdout).to include("Locks held (1):")
        expect(command.stdout).to include("Interrupted (1):")
        expect(command.stdout).to match(%r{^docs/\*\*\tcrashed-agent\t.*\tINTERRUPTED$})
        expect(command.stderr).to include("agent-lock resume docs/**")
        expect(command.stderr).to include("agent-lock break docs/**")
      end
    end

    # An agent harness reads both streams through one pipe, where STDOUT is
    # block-buffered and STDERR is not. Unflushed, every hint arrives before
    # the listing it belongs to. Only a real process has the buffering.
    it "prints each hint after the record it is about, even down one pipe" do
      plant("docs/**", agent: "crashed-agent", status: Agent::Lock::Record::ORPHANED)
      root = File.expand_path("../../..", __dir__)

      output, = Open3.capture2e(
        { "AGENT_ID" => "test-agent" },
        RbConfig.ruby, "-I", File.join(root, "lib"), File.join(root, "exe", "alo"), "list",
        chdir: expand_path(".")
      )

      expect(output.index("Interrupted (1):")).to be < output.index("alo resume docs/**")
    end

    it "says nothing is held when all that is left is interrupted work" do
      plant("docs/**", agent: "crashed-agent", status: Agent::Lock::Record::ORPHANED)

      command = agent_lock("list")

      aggregate_failures do
        expect(command.stdout).to include("No locks held.")
        expect(command.stdout).to include("Interrupted (1):")
      end
    end

    it "tags a live claim nobody has touched in hours STALE, and a fresh one not" do
      agent_lock("acquire workflow 'one'")
      plant("docs/**", agent: "slow-agent", age: 3 * 3600)

      lines = agent_lock("list").stdout.lines

      aggregate_failures do
        expect(lines.grep(/^docs/).first).to end_with("\tSTALE\n")
        expect(lines.grep(/^workflow/).first).not_to include("STALE")
      end
    end

    it "says in JSON which records are stale, beside which are interrupted" do
      agent_lock("acquire workflow 'one'")
      plant("docs/**", agent: "slow-agent", age: 3 * 3600)
      plant("notes/**", agent: "crashed-agent", status: Agent::Lock::Record::ORPHANED)

      parsed = JSON.parse(agent_lock("list --json").stdout).to_h { |record| [record["scope"], record] }

      aggregate_failures do
        expect(parsed["workflow/**"]).to include("stale" => false, "status" => "active")
        expect(parsed["docs/**"]).to include("stale" => true, "status" => "active")
        expect(parsed["notes/**"]).to include("stale" => false, "status" => "orphaned")
      end
    end

    it "tags the stale ones among this session's own" do
      plant("workflow/**", agent: "test-agent", age: 3 * 3600)

      expect(agent_lock("mine").stdout).to match(%r{^workflow/\*\*\ttest-agent\t.*\tSTALE$})
    end
  end

  describe "break" do
    it "takes a live lock, loudly" do
      agent_lock("acquire workflow 'one'")
      set_environment_variable("AGENT_ID", "somebody-else")

      command = agent_lock("break workflow")

      aggregate_failures do
        expect(command).to have_exit_status(0)
        expect(command.output).to include("BREAKING workflow/**")
      end
    end
  end

  # A hint is only worth printing if it can be pasted back. `agent-lock` said
  # to somebody who typed `alo` may not be on their PATH at all, or may be a
  # different program of the same name that shadows this one.
  describe "the name it was run as" do
    it "puts it in the hints it prints" do
      plant("workflow/**", agent: "crashed-agent", status: Agent::Lock::Record::ORPHANED)

      command = run_as("alo", "acquire workflow")

      aggregate_failures do
        expect(command).to have_exit_status(1)
        expect(command.stderr).to include("alo resume workflow/**")
        expect(command.stderr).not_to include("agent-lock")
      end
    end

    it "puts it in front of an error" do
      set_environment_variable("AGENT_LOCK_BACKEND", "carrier-pigeon")

      command = run_as("alo", "list")

      aggregate_failures do
        expect(command).to have_exit_status(2)
        expect(command.stderr).to start_with("ERROR: alo: unknown backend")
      end
    end

    it "is agent-lock when nobody says otherwise" do
      set_environment_variable("AGENT_LOCK_BACKEND", "carrier-pigeon")

      expect(agent_lock("list").stderr).to start_with("ERROR: agent-lock: unknown backend")
    end

    # Everything above builds the Launcher by hand. This is the one line that
    # production runs, and the only way to test it is to start the file.
    it "comes from the executable the process was started through" do
      root = File.expand_path("../../..", __dir__)
      _out, err, status = Open3.capture3(
        { "AGENT_LOCK_BACKEND" => "carrier-pigeon" },
        RbConfig.ruby, "-I", File.join(root, "lib"), File.join(root, "exe", "alo"), "list",
        chdir: expand_path(".")
      )

      aggregate_failures do
        expect(status.exitstatus).to eq(2)
        expect(err).to start_with("ERROR: alo: unknown backend")
      end
    end
  end

  describe "skill" do
    let(:into) { expand_path("installed-skills") }

    it "says where the bundled skill is, so a harness can link it instead" do
      command = agent_lock("skill path")

      aggregate_failures do
        expect(command).to have_exit_status(0)
        expect(File).to exist(File.join(command.stdout.strip, "SKILL.md"))
      end
    end

    it "installs the skill into a skills directory" do
      command = agent_lock("skill install --into #{into}")

      aggregate_failures do
        expect(command).to have_exit_status(0)
        expect(command.stdout).to include("INSTALLED #{File.join(into, "agent-lock")}")
        expect(File).to exist(File.join(into, "agent-lock", "SKILL.md"))
      end
    end

    it "says a second install changed nothing" do
      agent_lock("skill install --into #{into}")

      expect(agent_lock("skill install --into #{into}").stdout).to include("UP TO DATE")
    end

    it "refuses to overwrite a copy that differs, and says how to" do
      FileUtils.mkdir_p(File.join(into, "agent-lock"))
      File.write(File.join(into, "agent-lock", "SKILL.md"), "edited\n")

      command = agent_lock("skill install --into #{into}")

      aggregate_failures do
        expect(command).to have_exit_status(1)
        expect(command.stderr).to include("--force")
      end
    end
  end

  describe "the things a CLI gets wrong" do
    # dry-cli calls `exit` directly for help, which would take the whole suite
    # down if the Launcher did not catch it.
    it "prints help without taking the process down with it" do
      expect(agent_lock("--help").output).to include("acquire SCOPE [INTENT]")
    end

    it "refuses a command nobody implements" do
      expect(agent_lock("frobnicate")).not_to have_exit_status(0)
    end

    it "prints its version" do
      expect(agent_lock("version").output.strip).to eq(Agent::Lock::VERSION)
    end
  end
end

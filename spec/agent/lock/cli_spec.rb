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
        expect(command.stderr).to start_with("alo: unknown backend")
      end
    end

    it "is agent-lock when nobody says otherwise" do
      set_environment_variable("AGENT_LOCK_BACKEND", "carrier-pigeon")

      expect(agent_lock("list").stderr).to start_with("agent-lock: unknown backend")
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
        expect(err).to start_with("alo: unknown backend")
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

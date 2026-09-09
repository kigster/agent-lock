# frozen_string_literal: true

# The CLI end to end, in this process. Every exit code here is the one a shell
# would see, which is the half of a CLI's contract that is easiest to break and
# hardest to notice.
RSpec.describe Agent::Lock::CLI do
  include_context "a CLI"

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

      expect(parsed.first).to include("scope" => "workflow/**", "intent" => "one")
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

# frozen_string_literal: true

require "aruba/rspec"
require "fileutils"

# One working directory per rspec process, not the shared `tmp/aruba`. Aruba
# wipes its working directory before every example, so two runs in one
# checkout, which is what several agents in one worktree amount to, deleted
# each other's repositories and lock stores mid-example. The failures moved
# from run to run, and a wipe landing between `git init` and a command could
# send that command's locks into the checkout's own store.
ARUBA_WORKING_DIRECTORY = File.join("tmp", "aruba", Process.pid.to_s)

# In-process, not forked: Aruba instantiates the Launcher with its own streams
# and a fake Kernel, which is the whole reason the Launcher takes them as
# arguments. A suite that shells out spends most of its time starting Ruby.
Aruba.configure do |config|
  config.command_launcher = :in_process
  config.main_class = Agent::Lock::Launcher
  config.working_directory = ARUBA_WORKING_DIRECTORY
end

# A directory per process would otherwise pile up, one per run, forever.
at_exit { FileUtils.rm_rf(File.expand_path(ARUBA_WORKING_DIRECTORY, Aruba.config.root_directory)) }

RSpec.shared_context "a CLI" do
  include Aruba::Api

  before do
    setup_aruba
    # Aruba's working directory has to be a repository, since that is where the
    # store lives, and it has to be one this suite made rather than the one the
    # suite is running in.
    FileUtils.mkdir_p(expand_path("."))
    system("git", "init", "-q", "-b", "main", expand_path("."), out: File::NULL, err: File::NULL)

    # A tree with something in it: a scope naming a directory only means
    # "everything under it" if the directory is there to be seen.
    write_file("workflow/lib/cli.rb", "# stub\n")
    write_file("docs/api.md", "# stub\n")
    set_environment_variable("AGENT_ID", "test-agent")
  end

  # @param line [String] everything after `agent-lock`
  # @return [Aruba::Processes::InProcess]
  def agent_lock(line)
    # `run_command` starts an interactive process, which the in-process
    # launcher cannot be. This runs it to completion and hands back the result.
    run_command_and_stop("agent-lock #{line}", fail_on_error: false)
    last_command_started
  end

  # The CLI as `exe/alo` starts it, under a name of its own.
  #
  # Aruba builds its main class with five positional arguments and no way to
  # add a sixth, so the name goes into a one-off subclass instead. The config
  # is this example's own copy, so the swap cannot leak into the next one.
  #
  # @param program [String] what the user typed, e.g. "alo"
  # @param line [String] everything after the program name
  # @return [Aruba::Processes::InProcess]
  def run_as(program, line)
    aruba.config.main_class = Class.new(Agent::Lock::Launcher) do
      define_method(:initialize) { |*streams| super(*streams, program: program) }
    end
    run_command_and_stop("#{program} #{line}", fail_on_error: false)
    last_command_started
  ensure
    aruba.config.main_class = Agent::Lock::Launcher
  end
end

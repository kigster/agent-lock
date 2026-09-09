# frozen_string_literal: true

require "aruba/rspec"

# In-process, not forked: Aruba instantiates the Launcher with its own streams
# and a fake Kernel, which is the whole reason the Launcher takes them as
# arguments. A suite that shells out spends most of its time starting Ruby.
Aruba.configure do |config|
  config.command_launcher = :in_process
  config.main_class = Agent::Lock::Launcher
end

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
end

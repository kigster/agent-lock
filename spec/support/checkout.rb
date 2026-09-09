# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A throwaway git repository, for the specs that drive the library directly.
RSpec.shared_context "a checkout" do
  attr_reader :checkout

  around do |example|
    Dir.mktmpdir("agent-lock") do |dir|
      @checkout = File.realpath(dir)
      system("git", "init", "-q", "-b", "main", @checkout, out: File::NULL, err: File::NULL)
      FileUtils.mkdir_p(File.join(@checkout, "workflow", "lib"))
      File.write(File.join(@checkout, "workflow", "lib", "cli.rb"), "# stub\n")
      example.run
    end
  end

  # @return [Agent::Lock::Tree]
  def tree = Agent::Lock::Tree.for(checkout)

  # @param id [String] the session this manager belongs to
  # @return [Agent::Lock::Manager]
  def manager_for(id, parent: nil, **options)
    env = { "AGENT_ID" => id }
    env["AGENT_PARENT_ID"] = parent if parent
    Agent::Lock::Manager.new(tree: tree, identity: Agent::Lock::Identity.new(env: env), **options)
  end
end

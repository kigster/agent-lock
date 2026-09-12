# frozen_string_literal: true

require "fileutils"

module Agent
  module Lock
    # The skill this gem ships: a SKILL.md that teaches an agent how to claim
    # files with `alock`, copied into whichever skills directory the agent reads.
    #
    # It lives inside the gem rather than in a repository of its own so that
    # the instructions an agent follows can never describe a different version
    # of the tool than the one it runs.
    #
    # @example
    #   Agent::Lock::Skill.new(into: "~/.claude/skills").install.status  # => :installed
    class Skill
      # The skill's directory name, which is also the name it answers to.
      NAME = "agent-lock"

      # Where the gem keeps its skills, one directory each.
      ROOT = File.expand_path("../../../skills", __dir__)

      # What #install did, and where.
      Result = Data.define(:status, :path) do
        # @return [Integer] 1 when the install was refused, 0 otherwise
        def code = %i[differs linked].include?(status) ? 1 : 0
      end

      class << self
        # @return [String] the bundled skill's directory
        def source = File.join(ROOT, NAME)

        # @return [String] where most agents other than Claude Code look for
        #   a user's own skills; the CLI's `--for claude` points at
        #   `~/.claude/skills` instead
        def default_into = File.join(Dir.home, ".agents", "skills")
      end

      # @return [String] the skills directory being installed into
      attr_reader :into

      # @return [String] the skill directory being copied
      attr_reader :source

      # @param into [String] a skills directory, such as ~/.claude/skills
      # @param source [String] the skill to copy, the bundled one by default
      def initialize(into: self.class.default_into, source: self.class.source)
        @into = File.expand_path(into)
        @source = source
      end

      # @return [String] the directory the skill ends up in
      def target = File.join(into, NAME)

      # Copy the skill in, unless something is already there that this would
      # destroy. A copy that differs may be one somebody edited on purpose,
      # and a symlink is another installer's, such as a dotfiles repository
      # that links every skill it manages; replacing either without being
      # asked is the silent last-writer-wins this gem exists to prevent.
      #
      # @param force [Boolean] replace a copy that differs; never a symlink
      # @return [Result] :installed, :current, :differs or :linked
      def install(force: false)
        refused = refusal(force)
        return refused if refused

        FileUtils.rm_rf(target)
        FileUtils.mkdir_p(into)
        FileUtils.cp_r(source, target)
        result(:installed)
      end

      private

      # @param force [Boolean]
      # @return [Result, nil] why nothing should be copied, or nil to go ahead
      def refusal(force)
        return result(:linked) if File.symlink?(target)
        return result(:current) if current?

        result(:differs) if File.exist?(target) && !force
      end

      # @param status [Symbol]
      # @return [Result]
      def result(status) = Result.new(status: status, path: target)

      # @return [Boolean] the same files are there, byte for byte
      def current?
        return false unless File.directory?(target)

        wanted = files(source)
        wanted == files(target) &&
          wanted.all? { |rel| FileUtils.compare_file(File.join(source, rel), File.join(target, rel)) }
      end

      # @param dir [String]
      # @return [Array<String>] every file under it, relative and sorted
      def files(dir)
        Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).select { |rel| File.file?(File.join(dir, rel)) }.sort
      end
    end
  end
end

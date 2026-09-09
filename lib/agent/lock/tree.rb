# frozen_string_literal: true

require "digest"

module Agent
  module Lock
    # The working tree a lock is about, and where its locks are kept.
    #
    # Locks live in `<git-common-dir>/agent-locks`, which is chosen rather than
    # `~/.agent-locks` or a dotfile at the root for three reasons. Git cannot
    # track anything inside `.git`, so no repository needs a `.gitignore` line
    # and `git clean -xdf` cannot wipe the locks. Every worktree of a
    # repository resolves `--git-common-dir` to the same directory, so one
    # store serves all of them. And it dies with the checkout, instead of
    # outliving it in a home directory nobody thinks to sweep.
    #
    # Outside a repository the store falls back to `~/.agent-locks`, keyed by a
    # digest of the tree, since there is no `.git` to hide in.
    class Tree
      class << self
        # @param dir [String] anywhere inside the tree
        # @return [Tree]
        def for(dir = Dir.pwd) = new(dir)
      end

      # @return [String] absolute, symlinks resolved, so /tmp and /private/tmp
      #   cannot become two names for one tree
      attr_reader :root

      def initialize(dir = Dir.pwd)
        @dir = File.realpath(dir)
        @root = git("rev-parse", "--show-toplevel") || @dir
        @root = File.realpath(@root)
      end

      # @return [Boolean] a linked worktree rather than the original checkout
      def worktree? = !git_dir.nil? && git_dir != common_dir

      # @return [String] where locks for this tree are written
      def store_dir
        return File.expand_path(ENV["AGENT_LOCK_DIR"]) if ENV["AGENT_LOCK_DIR"]
        return File.join(common_dir, "agent-locks") if common_dir

        File.join(Dir.home, ".agent-locks", Digest::SHA256.hexdigest(root)[0, 12])
      end

      # @param path [String] anything the user typed
      # @return [String] that path relative to the tree root
      def relative(path)
        absolute = File.absolute_path(path, @dir)
        relative = absolute.delete_prefix("#{root}/")
        relative == absolute ? File.basename(absolute) : relative
      end

      private

      def git_dir = @git_dir ||= absolute(git("rev-parse", "--git-dir"))

      def common_dir = @common_dir ||= absolute(git("rev-parse", "--git-common-dir"))

      def absolute(dir)
        return nil if dir.nil?

        File.realpath(File.absolute_path(dir, @dir))
      rescue Errno::ENOENT
        nil
      end

      def git(*args)
        out = IO.popen(["git", "-C", @dir, *args], err: File::NULL, &:read).to_s.strip
        out.empty? ? nil : out
      rescue SystemCallError
        nil
      end
    end
  end
end

# frozen_string_literal: true

require "digest"
require_relative "scope"

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

      # @description Resolves the directory where locks are stored by either
      # $AGENT_LOCK_DIR environment variable if defined, or 'agent-locks'
      # inside .git if available, or the ~/.agent-locks/<tree-digest> in user's
      # home folder.
      # @return [String] where locks for this tree are written
      def store_dir
        return File.expand_path(ENV["AGENT_LOCK_DIR"]) if ENV["AGENT_LOCK_DIR"]
        return File.join(common_dir, "agent-locks") if common_dir

        File.join(Dir.home, ".agent-locks", ::Digest::SHA256.hexdigest(root)[0, 12])
      end

      # A path the user typed, read from where they stand, as a name inside
      # this tree.
      #
      # There used to be a fallback to the basename for anything outside the
      # root, so `/etc/passwd` quietly locked the tree's own `passwd`: an agent
      # was told it held something it had never asked for, and the thing it had
      # asked for stayed unguarded. Outside is now an error.
      #
      # The path is compared as typed first, then with symlinks resolved, so an
      # alias of the tree (`/tmp` for `/private/tmp`) is still inside it, while
      # an in-tree symlink that points elsewhere keeps its in-tree name, which is
      # what the lock is about. The path need not exist: an agent claims a file
      # before writing it.
      #
      # @param path [String] anything the user typed, absolute or relative
      # @return [String] that path relative to the root, "." for the root itself
      # @raise [Scope::Invalid] when the path resolves outside the tree
      def relative(path)
        absolute = File.absolute_path(path, @dir)
        inside(absolute) || inside(resolve(absolute)) ||
          raise(Scope::Invalid, "#{path} is outside the tree #{root}")
      end

      private

      # The prefix test that `delete_prefix` alone got wrong: `/repo-other`
      # starts with `/repo`, so the root is matched only whole or up to a slash.
      #
      # @param absolute [String]
      # @return [String, nil] relative to the root, or nil when outside it
      def inside(absolute)
        return "." if absolute == root

        prefix = root.end_with?("/") ? root : "#{root}/"
        absolute.delete_prefix(prefix) if absolute.start_with?(prefix)
      end

      # Symlinks resolved in the deepest part of the path that exists, with the
      # rest appended, since `File.realpath` refuses a file not yet written.
      #
      # @param absolute [String]
      # @return [String]
      def resolve(absolute)
        head = absolute
        tail = []
        until File.exist?(head)
          tail.unshift(File.basename(head))
          head = File.dirname(head)
        end
        File.join(File.realpath(head), *tail)
      rescue SystemCallError
        absolute
      end

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

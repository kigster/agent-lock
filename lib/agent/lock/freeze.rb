# frozen_string_literal: true

require_relative "error"

module Agent
  module Lock
    # Optional teeth, for the scope you want nobody to touch at all.
    #
    # An advisory lock works because every agent checks it. That covers the
    # agents that check. `chflags uchg` on macOS makes the file unwritable by
    # anything, checking or not, which is the right answer for a handful of
    # files that must not move while something else runs.
    #
    # It is opt-in for three reasons. It is macOS only, since Linux's `chattr
    # +i` needs root. It denies the holder too, so it fits a freeze rather than
    # a file you are editing. And a session that dies with files frozen leaves
    # a tree where `git checkout` and `rm -rf` fail with "Operation not
    # permitted", which is why every frozen path is written into the lock: the
    # thaw does not depend on the process that froze them still being alive.
    module Freeze
      # A freeze walks and flags every matched file, so a scope covering a
      # whole checkout is a mistake rather than an instruction.
      LIMIT = 500

      # How many paths one `chflags` invocation is given.
      BATCH = 200

      class TooBroad < Error; end

      module_function

      # @return [Boolean]
      def supported? = RUBY_PLATFORM.include?("darwin")

      # @param scope [Scope]
      # @param tree [Tree]
      # @return [Array<String>] the files it would freeze, relative to the root
      def matches(scope, tree)
        Dir.glob(recursive(scope.pattern), base: tree.root, flags: File::FNM_EXTGLOB)
           .select { |rel| File.file?(File.join(tree.root, rel)) }
           .reject { |rel| rel.start_with?(".git/") }
           .sort
      end

      # A trailing `**` means "everything under here" to this gem, and to
      # anybody typing it. It does not mean that to Dir.glob, where a bare
      # `**` at the end matches one level, exactly like `*`. Only `**/` walks
      # down. So a scope that covers a subtree is spelled out before globbing.
      #
      # @param pattern [String]
      # @return [String]
      def recursive(pattern) = pattern.end_with?("**") ? "#{pattern}/*" : pattern

      # @param paths [Array<String>] relative to the tree root
      # @param tree [Tree]
      # @param force [Boolean] allow a freeze wider than LIMIT
      # @return [Array<String>] what was frozen
      def apply(paths, tree:, force: false)
        raise TooBroad, "--enforce needs macOS; this is #{RUBY_PLATFORM}" unless supported?
        return [] if paths.empty?
        raise TooBroad, "#{paths.size} files is wider than a freeze should be" if paths.size > LIMIT && !force

        chflags("uchg", paths, tree)
      end

      # Best effort on purpose: a path that has since been deleted or already
      # thawed is not a reason to leave the rest frozen.
      #
      # @return [Array<String>] what was thawed
      def clear(paths, tree:)
        return [] if paths.nil? || paths.empty?

        chflags("nouchg", paths, tree)
      end

      # Only the files `chflags` actually accepted come back.
      #
      # A batch that fails is retried one file at a time, because the usual
      # reason is a single path somebody else owns, and reporting the whole
      # batch as frozen would leave the lock claiming protection it does not
      # have. Reporting the whole batch as failed would be just as wrong.
      #
      # @return [Array<String>] relative paths that are now flagged
      def chflags(flag, paths, tree)
        return [] unless supported?

        paths.each_slice(BATCH)
             .flat_map { |batch| flag_batch(flag, existing(batch, tree)) }
             .map { |path| path.delete_prefix("#{tree.root}/") }
      end

      # @return [Array<String>] absolute paths that are still there to flag
      def existing(batch, tree)
        batch.map { |rel| File.join(tree.root, rel) }.select { |path| File.exist?(path) }
      end

      # @return [Array<String>] the ones the command accepted
      def flag_batch(flag, absolute)
        return [] if absolute.empty?
        return absolute if run(flag, absolute)

        absolute.select { |path| run(flag, [path]) }
      end

      # @return [Boolean] whether the command reported success
      def run(flag, paths) = system("chflags", flag, *paths, out: File::NULL, err: File::NULL) || false
    end
  end
end

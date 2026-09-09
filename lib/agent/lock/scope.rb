# frozen_string_literal: true

module Agent
  module Lock
    # What a lock covers: one path, or a glob over many.
    #
    # `**` is the whole tree, `workflow/**` a corner of it, `lib/a.rb` a single
    # file. A directory is taken to mean everything under it, since an agent
    # that says it is working in `docs` is not promising to leave `docs/api`
    # alone.
    #
    # Two scopes conflict when either one's fixed part contains the other's.
    # `workflow/**` and `workflow/lib/cli.rb` conflict; `docs/**` and
    # `workflow/**` do not. Comparing the fixed parts rather than trying to
    # intersect two globs is deliberate: glob intersection has answers nobody
    # can predict, and the failure it would buy is two agents editing one file.
    # This errs the other way, toward refusing work that might have been safe.
    class Scope
      ALL = "**"

      # @return [String] the pattern, relative to the tree root
      attr_reader :pattern

      class << self
        # @param path [String] a path or a glob, absolute or relative
        # @param tree [Tree]
        # @return [Scope]
        def parse(path, tree:)
          text = path.to_s.strip
          return new(ALL) if text.empty? || text == "." || text == ALL || text == "*"

          text = tree.relative(text) unless glob?(text)
          text = "#{text.chomp("/")}/#{ALL}" if directory?(text, tree)
          new(text)
        end

        def glob?(text) = text.match?(/[*?\[{]/)

        def directory?(text, tree)
          return false if glob?(text)

          File.directory?(File.join(tree.root, text))
        end
      end

      def initialize(pattern)
        @pattern = pattern.to_s.squeeze("/").delete_prefix("./")
      end

      # The leading segments with no wildcard in them, which is the deepest
      # directory a pattern is certainly confined to.
      #
      # @return [String] "" for a pattern that starts with a wildcard
      def fixed_part
        @fixed_part ||= pattern.split("/").take_while { |part| !self.class.glob?(part) }.join("/")
      end

      # @param other [Scope]
      # @return [Boolean]
      def conflicts_with?(other)
        return true if pattern == other.pattern

        contains?(fixed_part, other.fixed_part) || contains?(other.fixed_part, fixed_part)
      end

      # @return [String] safe to use in a filename
      def slug
        text = pattern.gsub("**", "all").gsub(%r{[^A-Za-z0-9._/-]}, "").tr("/", "-").squeeze("-")
        text = text.delete_prefix("-").delete_suffix("-")
        text.empty? ? "tree" : text[0, 60]
      end

      def to_s = pattern

      def ==(other) = other.is_a?(Scope) && pattern == other.pattern

      private

      # @return [Boolean] whether `outer` is `inner` or an ancestor of it
      def contains?(outer, inner)
        return true if outer.empty? || outer == inner

        inner.start_with?("#{outer}/")
      end
    end
  end
end

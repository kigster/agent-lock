# frozen_string_literal: true

require_relative "error"

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
      # A scope the tree cannot honestly lock: empty, or somewhere else. Raised
      # rather than guessed at, since every guess so far locked the wrong thing
      # and reported success. An `Error`, so the launcher exits 2 with the
      # message, which is written for the agent that has to fix its argument.
      class Invalid < Error; end

      ALL = "**"

      # The spellings of the whole tree, taken literally wherever the agent
      # stands.
      WHOLE_TREE = [".", "*", ALL].freeze

      EMPTY = "empty scope: pass ** to claim the whole tree"

      # @return [String] the pattern, relative to the tree root
      attr_reader :pattern

      class << self
        # What the user typed, as a pattern relative to the tree root.
        #
        # An empty scope used to mean the whole tree, so `alo acquire "$SCOPE"`
        # with the variable unset claimed everything, and nobody asked for
        # that. Globs used to skip the tree entirely, so `../x/**` was stored
        # verbatim and `/abs/tree/lib/**` never met `lib/**`. Both are read
        # the way a plain path is now.
        #
        # @param path [String] a path or a glob, absolute or relative
        # @param tree [Tree]
        # @return [Scope]
        # @raise [Invalid] when the scope is empty, or resolves outside the tree
        def parse(path, tree:)
          text = path.to_s.strip
          raise Invalid, EMPTY if text.empty?
          return new(ALL) if WHOLE_TREE.include?(text)

          text = glob?(text) ? relative_glob(text, tree) : tree.relative(text)
          return new(ALL) if text == "."

          text = "#{text}/#{ALL}" if directory?(text, tree)
          new(text)
        end

        # @param text [String]
        # @return [Boolean] whether it has a wildcard anywhere in it
        def glob?(text) = text.match?(/[*?\[{]/)

        # @param text [String] relative to the tree root
        # @param tree [Tree]
        # @return [Boolean] a plain path naming a directory that exists
        def directory?(text, tree)
          return false if glob?(text)

          File.directory?(File.join(tree.root, text))
        end

        private

        # A glob with its fixed part, everything before the segment holding
        # the first wildcard, read through the tree as a plain path would be.
        # The wildcards are kept as typed.
        #
        # @param text [String] a glob, absolute or relative
        # @param tree [Tree]
        # @return [String] the glob relative to the tree root
        # @raise [Invalid] when the fixed part is outside the tree, or a `..`
        #   follows a wildcard
        def relative_glob(text, tree)
          fixed, wild = split(text)
          # The fixed part is what was checked against the tree; a `..` after a
          # wildcard climbs past it to somewhere nobody checked.
          if wild.split("/").include?("..")
            raise Invalid, "#{text}: a .. after a wildcard could leave the tree; spell the path without it"
          end

          base = tree.relative(fixed.empty? ? "." : fixed)
          base == "." ? wild : "#{base}/#{wild}"
        end

        # @param text [String] a glob
        # @return [Array(String, String)] the fixed part, "/" for a glob at the
        #   filesystem root, and the rest from the first wildcard's segment on
        def split(text)
          cut = text.rindex("/", text.index(/[*?\[{]/))
          return ["", text] if cut.nil?
          return ["/", text[1..]] if cut.zero?

          [text[0...cut], text[(cut + 1)..]]
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

      # Whether holding this scope already means holding `other`, which is a
      # stricter question than whether the two overlap. Only a scope that
      # takes everything under a directory can promise that; a partial glob
      # such as `lib/*.rb` covers nothing but itself, since working out what
      # else it matches is the guessing #conflicts_with? refuses to do.
      #
      # @example
      #   Scope.new("lib/**").covers?(Scope.new("lib/cli.rb"))   # => true
      #   Scope.new("lib/cli.rb").covers?(Scope.new("lib/**"))   # => false
      #
      # @param other [Scope]
      # @return [Boolean]
      def covers?(other)
        return true if pattern == other.pattern

        recursive? && contains?(fixed_part, other.fixed_part)
      end

      # @return [Boolean] the whole tree, or everything under one directory
      def recursive? = [ALL, "#{fixed_part}/#{ALL}"].include?(pattern)

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

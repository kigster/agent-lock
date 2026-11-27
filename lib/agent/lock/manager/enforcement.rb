# frozen_string_literal: true

require_relative "../freeze"

module Agent
  module Lock
    class Manager
      # `acquire --enforce`: freezing the files of a lock already won.
      #
      # Freezing happens after the claim is won, never before. Flagging files
      # first and then losing the race would leave a tree full of unwritable
      # files that no lock admits to having frozen, which is the one failure
      # this whole feature is supposed to prevent.
      class Enforcement
        # @param tree [Tree]
        # @param store [Store::FileSystemStore, Store::RedisStore]
        def initialize(tree, store)
          @tree = tree
          @store = store
        end

        # @param record [Record] the lock, already created
        # @param scope [Scope]
        # @param wide [Boolean] freeze even a scope wider than Freeze::LIMIT files
        # @return [Array(Record, String)] the lock with its frozen paths, and a
        #   warning, or nil, when the filesystem refused some of them
        # @raise [Freeze::TooBroad] when the scope is too wide and `wide` is false
        def apply(record, scope, wide:)
          wanted = Freeze.matches(scope, @tree)
          frozen = Freeze.apply(wanted, tree: @tree, wide: wide)
          updated = record.with(frozen_paths: frozen)
          @store.update(updated)
          [updated, shortfall(wanted, frozen)]
        end

        private

        # @param wanted [Array<String>] the files the scope matched
        # @param frozen [Array<String>] the ones `chflags` accepted
        # @return [String, nil] said only when the filesystem refused some of it
        def shortfall(wanted, frozen)
          missed = wanted.size - frozen.size
          return nil if missed.zero?

          "could not freeze #{missed} of #{wanted.size} file(s); the lock still stands"
        end
      end
    end
  end
end

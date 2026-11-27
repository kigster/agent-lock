# frozen_string_literal: true

require_relative "../freeze"

module Agent
  module Lock
    class Manager
      # `acquire --enforce`: freezing the files of a lock already won, and
      # writing down which ones.
      #
      # Freezing happens after the claim is won, never before. Flagging files
      # first and then losing the race would leave a tree full of unwritable
      # files that no lock admits to having frozen, which is the one failure
      # this whole feature is supposed to prevent.
      #
      # The walk and `chflags` run outside the store's mutex, since every
      # other session would be waiting on them. That leaves a window in which
      # the lock can be noted, broken, or broken and taken by somebody else,
      # and a record's id is only its tree and scope, so the newcomer's lock
      # has the id of the one this call won. Writing the record captured
      # before the walk back over it lost the note, brought a broken lock
      # back, or replaced another agent's lock with this one; deleting it by
      # id on a refused freeze deleted the other agent's. So both writes go
      # back under the mutex and act only on the claim this call won, read
      # again: {#standing}.
      class Enforcement
        # @param tree [Tree]
        # @param store [Store::FileSystemStore, Store::RedisStore]
        def initialize(tree, store)
          @tree = tree
          @store = store
        end

        # Not for use inside the store's mutex, which it takes itself.
        #
        # @param record [Record] the lock, already created
        # @param scope [Scope]
        # @param wide [Boolean] freeze even a scope wider than Freeze::LIMIT files
        # @return [Array(Record, String)] the lock with its frozen paths, and a
        #   warning, or nil, when the filesystem refused some of them. The
        #   record is nil when the claim did not outlast the freeze: nothing
        #   is left frozen, and whatever stands in the store is untouched
        # @raise [Freeze::TooBroad] when the scope is too wide and `wide` is
        #   false. Nothing was flagged, and the claim is dropped with the
        #   freeze, not left standing unenforced
        def apply(record, scope, wide:)
          wanted = Freeze.matches(scope, @tree)
          frozen = Freeze.apply(wanted, tree: @tree, wide: wide)
          [@store.synchronize { settle(record, scope, frozen) }, shortfall(wanted, frozen)]
        rescue Freeze::TooBroad
          @store.synchronize { standing(record, @store.find(scope))&.then { |current| @store.delete(current) } }
          raise
        end

        private

        # @param record [Record] the lock as it was won
        # @param scope [Scope]
        # @param frozen [Array<String>] the files `chflags` accepted
        # @return [Record, nil] the standing lock with its frozen paths, or
        #   nil, with the files thawed, when the claim is gone
        def settle(record, scope, frozen)
          found = @store.find(scope)
          current = standing(record, found)
          return current.with(frozen_paths: frozen).tap { |updated| @store.update(updated) } if current

          # Whoever took the scope in the meantime may have frozen the same
          # files under a lock of their own, and those stay frozen.
          Freeze.clear(frozen - Array(found&.frozen_paths), tree: @tree)
          nil
        end

        # The claim this call won, as the store holds it now: notes and all.
        # The same id under another holder, or taken at another time, is
        # somebody else's lock.
        #
        # @param record [Record] the lock as it was won
        # @param found [Record, nil] what the store holds under that id now
        # @return [Record, nil] nil when it was broken, released or replaced
        def standing(record, found)
          return nil unless found&.active?

          found if [found.agent_id, found.created_at] == [record.agent_id, record.created_at]
        end

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

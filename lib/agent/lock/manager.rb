# frozen_string_literal: true

require_relative "freeze"
require_relative "identity"
require_relative "manager/enforcement"
require_relative "record"
require_relative "scope"
require_relative "store"
require_relative "tree"

module Agent
  module Lock
    # Every decision this gem makes, with nothing printed.
    #
    # Each verb returns a Result: a status the caller switches on, the records
    # involved, and the exit code the CLI should hand back. Keeping the
    # decisions here and the wording in the commands is what lets the whole
    # lifecycle be tested without capturing output.
    class Manager
      # What every Manager verb returns.
      #
      # @!attribute [r] status
      #   @return [Symbol] what happened, such as :acquired, :held or :not_found
      # @!attribute [r] records
      #   @return [Array<Record>] the records involved, the subject first
      # @!attribute [r] message
      #   @return [String, nil] a warning worth printing, such as a partial freeze
      Result = Data.define(:status, :records, :message) do
        # @return [Integer] what the process should exit with
        def code = %i[held refused not_found interrupted parent_scope].include?(status) ? 1 : 0

        # @return [Record, nil] the one record most results are about
        def record = records.first
      end

      # Minutes untouched before a lock is reported STALE, and before one
      # whose holder cannot be checked expires. AGENT_LOCK_STALE_MINUTES
      # overrides it.
      DEFAULT_STALE_MINUTES = 120

      # @!attribute [r] tree
      #   @return [Tree] the checkout this manager works on
      # @!attribute [r] store
      #   @return [Store::FileSystemStore, Store::RedisStore] where its locks are kept
      # @!attribute [r] identity
      #   @return [Identity] who every lock it takes is signed by
      attr_reader :tree, :store, :identity

      # @param tree [Tree] the checkout to work on
      # @param identity [Identity] who the locks are signed by
      # @param stale_minutes [Integer, nil] nil reads AGENT_LOCK_STALE_MINUTES
      # @param store [FileSystemStore, RedisStore, nil] nil picks the tree's backend
      def initialize(tree: Tree.for, identity: Identity.current, stale_minutes: nil, store: nil)
        @tree = tree
        @store = store || Store.for(tree)
        @identity = identity
        @stale_minutes = stale_minutes
      end

      # @return [Integer] how long a lock whose holder cannot be checked is
      #   trusted for, and how long a live one goes untouched before it is
      #   reported stale
      def stale_minutes
        @stale_minutes ||= Integer(ENV.fetch("AGENT_LOCK_STALE_MINUTES", DEFAULT_STALE_MINUTES))
      end

      # Claim a scope, unless something overlapping stands in the way.
      #
      # The scan for conflicts and the write it justifies happen inside the
      # store's mutex. `create` refuses only an identical scope, so without it
      # ten sessions claiming `lib/**` and `lib/a.rb` at once each saw a clear
      # field and each wrote a lock, leaving overlapping claims that all
      # reported success. Freezing stays outside: it walks the tree and runs
      # `chflags`, and every other session would be waiting on it. What it
      # writes afterwards goes back under the mutex: see {Enforcement}.
      #
      # @param path [String] a path or a glob
      # @param intent [String]
      # @param enforce [Boolean] also make the matched files unwritable
      # @param wide [Boolean] freeze even a scope wider than Freeze::LIMIT files
      # @return [Result] :acquired, or :already_mine, :held, :parent_scope or
      #   :interrupted with the records that explain why not. With `enforce`,
      #   :held also answers a lock that was broken while its files were
      #   being frozen, with whoever holds the scope now
      def acquire(path, intent: "unspecified", enforce: false, wide: false)
        scope = Scope.parse(path, tree: tree)
        outcome = store.synchronize { take(scope, intent) }
        return outcome unless enforce && outcome.status == :acquired

        enforce_on(outcome.record, scope, wide: wide)
      end

      # @param path [String]
      # @return [Result]
      def release(path)
        scope = Scope.parse(path, tree: tree)
        store.synchronize do
          record = locate(scope, prefer: ->(found) { found.held_by?(identity) })
          next result(:not_found, []) if record.nil?
          next result(:refused, [record]) unless record.held_by?(identity)

          drop(record)
          result(:released, [record])
        end
      end

      # Whether this session may write in a scope. A parent's lock alone does
      # not make it :mine, since the child still has to claim its own corner
      # before its siblings can see it there; to the child, that scope is
      # :free to claim.
      #
      # @param path [String]
      # @return [Result] :held, :mine or :free
      def check(path)
        scope = Scope.parse(path, tree: tree)
        blocking, family = after_reap { conflicts(scope).partition { |record| record.blocks?(identity) } }
        return result(:held, blocking) if blocking.any?

        own = family.select { |record| record.held_by?(identity) }
        own.any? ? result(:mine, own) : result(:free, [])
      end

      # @return [Result] every lock in the store, this tree's siblings included
      def list
        result(:listed, after_reap { store.all })
      end

      # @return [Result]
      def mine
        result(:listed, after_reap { store.all.select { |record| record.held_by?(identity) } })
      end

      # @return [Result]
      def release_all
        held = store.synchronize do
          store.all.select { |record| record.held_by?(identity) }.each { |record| drop(record) }
        end
        result(:released, held)
      end

      # @param path [String]
      # @return [Result]
      def break_lock(path)
        scope = Scope.parse(path, tree: tree)
        store.synchronize do
          record = locate(scope)
          next result(:not_found, []) if record.nil?

          drop(record)
          result(:broken, [record])
        end
      end

      # Locks whose holder is provably gone, or, for a holder on another host
      # that cannot be asked, that nobody has touched in so long that nobody
      # can say. A live holder's lock is never among them, however old; see
      # Record#expired?. Reaped before any decision that depends on them,
      # never on a schedule.
      #
      # A lock with nothing written in it is deleted. One whose holder wrote
      # down what it was doing is orphaned instead: the process is gone, the
      # claim is void, but the notes are the only record of work interrupted
      # halfway, and a reboot is the most likely reason there are any. Whoever
      # comes next sees them, and `resume` takes the lock and the notes back.
      #
      # Takes the store's mutex, so it is not for use inside another
      # `synchronize`: the verbs here call {#sweep} there instead.
      #
      # @return [Array<Record>] what it cleared out of the way
      def reap = store.synchronize { sweep }

      # Write a line into a lock this session holds, so that a machine coming
      # back up has something better than the diff to work out where it was.
      #
      # @param path [String]
      # @param text [String]
      # @return [Result]
      def note(path, text)
        scope = Scope.parse(path, tree: tree)
        store.synchronize do
          record = locate(scope, prefer: ->(found) { found.held_by?(identity) })
          next result(:not_found, []) if record.nil?
          next result(:refused, [record]) unless record.held_by?(identity)

          updated = record.note(text)
          store.update(updated)
          result(:noted, [updated])
        end
      end

      # Take an interrupted lock back, notes and all.
      #
      # Inside the store's mutex, because the check and the write are two
      # steps: two sessions resuming one orphan would otherwise both find it
      # interrupted, both write themselves in, and both report :resumed.
      #
      # An orphan blocks nobody, so while it sat there somebody may have
      # claimed an overlapping scope; that claim is checked for exactly as
      # `acquire` would check it. And the resumed claim covers the branch this
      # checkout is on now, not the one the orphan was taken on: it is rebound
      # to the current tree, so that other checkouts of this branch see it.
      #
      # @param path [String]
      # @return [Result] :resumed, :not_found, or :held with what overlaps
      def resume(path)
        scope = Scope.parse(path, tree: tree)
        store.synchronize do
          sweep
          record = locate(scope, prefer: :orphaned?.to_proc)
          next result(:not_found, []) if record.nil? || record.active?

          blocking = conflicts(scope).select { |other| other.blocks?(identity) }
          next result(:held, blocking) if blocking.any?

          rebind(record, scope)
        end
      end

      private

      # Reads the store with the reaping that precedes it under one hold of
      # the mutex, so no other writer lands between the two. Not for use
      # inside another `synchronize`: the file store's flock is not
      # re-entrant.
      #
      # @yield the read
      # @return [Object] whatever the block returns
      def after_reap
        store.synchronize do
          sweep
          yield
        end
      end

      # {#reap} without the mutex, for a caller already holding it.
      #
      # @return [Array<Record>] what it cleared out of the way
      def sweep
        store.all.select { |record| record.active? && record.expired?(stale_minutes) }.map do |record|
          record.notes? ? orphan(record) : drop(record)
          record
        end
      end

      # The critical section of #acquire: the scan, and the write it justifies.
      #
      # @param scope [Scope]
      # @param intent [String]
      # @return [Result]
      def take(scope, intent)
        sweep
        refusal = why_not(scope)
        return refusal if refusal

        record = Record.build(scope: scope, tree: tree, identity: identity, intent: intent)
        store.create(record) ? result(:acquired, [record]) : result(:held, conflicts(scope))
      end

      # Everything standing between this session and the scope it asked for,
      # in the order the caller can do something about.
      #
      # @param scope [Scope]
      # @return [Result, nil] nil when the scope is there to be taken
      def why_not(scope)
        blocking, family = conflicts(scope).partition { |record| record.blocks?(identity) }
        own, inherited = family.partition { |record| record.held_by?(identity) }

        # First, because no amount of waiting fixes it. Records are keyed by
        # tree and scope, so the parent's record is the one this child would
        # have to write, and `create` would refuse it as though a stranger
        # held the scope.
        umbrella = exactly(scope, inherited)
        return result(:parent_scope, [umbrella]) if umbrella
        return result(:held, blocking) if blocking.any?

        # Only this session's own lock covers it, and only one that contains
        # the scope. Taking a second lock inside your own would leave a stale
        # one behind on release. A parent's lock does not count: a child that
        # stopped there recorded nothing, and two siblings both "acquired" the
        # same file. Nor does a narrower lock of your own: holding one file and
        # being told the whole tree was yours left the rest of it open.
        covering = covering(scope, own)
        return result(:already_mine, covering) if covering.any?

        interrupted(scope)
      end

      # @param scope [Scope]
      # @param records [Array<Record>] this session's own overlapping locks
      # @return [Array<Record>] the ones that contain the whole of `scope`
      def covering(scope, records) = records.select { |record| record.scope_object.covers?(scope) }

      # @param scope [Scope]
      # @param records [Array<Record>]
      # @return [Record, nil] the one stored under this scope's own id
      def exactly(scope, records) = records.find { |record| record.id == Record.id_for(tree, scope) }

      # An orphan sitting on this exact scope is somebody's interrupted work.
      # Overwriting it would take the only record of it, so say so and let the
      # caller choose `resume` or `break`.
      #
      # @param scope [Scope]
      # @return [Result, nil]
      def interrupted(scope)
        record = store.find(scope)
        result(:interrupted, [record]) if record&.orphaned?
      end

      # See {Enforcement}.
      #
      # @param record [Record] the lock, already created
      # @param scope [Scope]
      # @param wide [Boolean] freeze even a scope wider than Freeze::LIMIT files
      # @return [Result]
      def enforce_on(record, scope, wide:)
        updated, shortfall = Enforcement.new(tree, store).apply(record, scope, wide:)
        return result(:acquired, [updated], shortfall) if updated

        result(:held, store.synchronize { conflicts(scope) },
               "#{scope} was broken while its files were being frozen; nothing is frozen")
      end

      # Orphaned locks are left out: they carry the notes of a session that
      # died, which is information rather than a claim, and a machine that
      # rebooted should not lock its owner out of their own checkout.
      #
      # @param scope [Scope]
      # @return [Array<Record>]
      def conflicts(scope)
        store.all.select do |record|
          record.active? && record.about?(tree) && record.scope_object.conflicts_with?(scope)
        end
      end

      # The frozen paths of a lock taken in another checkout, or on another
      # machine, name files that are not here. Clearing them would unfreeze
      # this checkout's files of the same name, which may be frozen under a
      # lock of its own, so they are left alone. An orphan keeps the list, so
      # the checkout that froze them can still see what to thaw.
      #
      # @param record [Record]
      # @return [void]
      def orphan(record)
        local = record.local_to?(tree)
        Freeze.clear(record.frozen_paths, tree: tree) if local
        store.update(record.with(status: Record::ORPHANED, frozen_paths: local ? [] : record.frozen_paths,
                                 updated_at: Time.now.utc.iso8601))
      end

      # @param record [Record]
      # @return [void]
      def drop(record)
        Freeze.clear(record.frozen_paths, tree: tree) if record.local_to?(tree)
        store.delete(record)
      end

      # The lock this tree holds on a scope. Looked up by id first, which is
      # the whole point of the id, and then by scope among this checkout's own,
      # because the id carries the branch: a session that switched branches
      # after claiming would otherwise be told its own lock was not there, and
      # could neither release nor resume it.
      #
      # Both can exist at once: this checkout's lock from `main`, and another
      # checkout's lock on the same scope on the branch this one has since
      # switched to. `prefer` picks which one a command is after, so `release`
      # finds the lock it owns rather than refusing on somebody else's.
      #
      # @param scope [Scope]
      # @param prefer [Proc, nil] the record wanted when there is a choice
      # @return [Record, nil]
      def locate(scope, prefer: nil)
        found = [store.find(scope), *store.all.select { |record| record.scope == scope.to_s && record.local_to?(tree) }]
                .compact.uniq(&:id)
        (prefer && found.find(&prefer)) || found.first
      end

      # An orphan made a live claim again, by this session, on this tree's
      # current branch. When the branch moved, the id moves with it: the new
      # record is created first, so a lost race leaves the orphan where it
      # was, and the old one is deleted only once the new one stands.
      #
      # @param record [Record] the orphan
      # @param scope [Scope]
      # @return [Result]
      def rebind(record, scope)
        adopted = record.resumed(tree: tree, scope: scope, identity: identity)
        moved = adopted.id != record.id
        return result(:interrupted, [store.find(scope)].compact) if moved && !store.create(adopted)

        moved ? store.delete(record) : store.update(adopted)
        result(:resumed, [adopted])
      end

      # @param status [Symbol]
      # @param records [Array<Record>]
      # @param message [String, nil]
      # @return [Result]
      def result(status, records, message = nil) = Result.new(status:, records:, message:)
    end
  end
end

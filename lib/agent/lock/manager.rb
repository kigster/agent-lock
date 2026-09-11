# frozen_string_literal: true

require_relative "freeze"
require_relative "identity"
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
      Result = Data.define(:status, :records, :message) do
        # @return [Integer] what the process should exit with
        def code = %i[held refused not_found interrupted parent_scope].include?(status) ? 1 : 0

        # @return [Record, nil] the one record most results are about
        def record = records.first
      end

      DEFAULT_STALE_MINUTES = 120

      attr_reader :tree, :store, :identity

      def initialize(tree: Tree.for, identity: Identity.current, stale_minutes: nil, store: nil)
        @tree = tree
        @store = store || Store.for(tree)
        @identity = identity
        @stale_minutes = stale_minutes
      end

      # @return [Integer] how long a lock nobody can disprove is trusted for
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
      # `chflags`, and every other session would be waiting on it.
      #
      # @param path [String] a path or a glob
      # @param intent [String]
      # @param enforce [Boolean] also make the matched files unwritable
      # @param force [Boolean] freeze even a very wide scope
      # @return [Result] :acquired, or :already_mine, :held, :parent_scope or
      #   :interrupted with the records that explain why not
      def acquire(path, intent: "unspecified", enforce: false, force: false)
        scope = Scope.parse(path, tree: tree)
        outcome = store.synchronize { take(scope, intent) }
        return outcome unless enforce && outcome.status == :acquired

        enforce_on(outcome.record, scope, force: force)
      end

      # @param path [String]
      # @return [Result]
      def release(path)
        scope = Scope.parse(path, tree: tree)
        record = store.find(scope)
        return result(:not_found, []) if record.nil?
        return result(:refused, [record]) unless record.held_by?(identity)

        drop(record)
        result(:released, [record])
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
        reap
        blocking, family = conflicts(scope).partition { |record| record.blocks?(identity) }
        return result(:held, blocking) if blocking.any?

        own = family.select { |record| record.held_by?(identity) }
        own.any? ? result(:mine, own) : result(:free, [])
      end

      # @return [Result] every lock in the store, this tree's siblings included
      def list = result(:listed, store.all)

      # @return [Result]
      def mine = result(:listed, store.all.select { |record| record.held_by?(identity) })

      # @return [Result]
      def release_all
        held = store.all.select { |record| record.held_by?(identity) }
        held.each { |record| drop(record) }
        result(:released, held)
      end

      # @param path [String]
      # @return [Result]
      def break_lock(path)
        scope = Scope.parse(path, tree: tree)
        record = store.find(scope)
        return result(:not_found, []) if record.nil?

        drop(record)
        result(:broken, [record])
      end

      # Locks whose holder is provably gone, or that nobody has touched in so
      # long that nobody can say. Reaped before any decision that depends on
      # them, never on a schedule.
      #
      # A lock with nothing written in it is deleted. One whose holder wrote
      # down what it was doing is orphaned instead: the process is gone, the
      # claim is void, but the notes are the only record of work interrupted
      # halfway, and a reboot is the most likely reason there are any. Whoever
      # comes next sees them, and `resume` takes the lock and the notes back.
      #
      # @return [Array<Record>] what it cleared out of the way
      def reap
        store.all.select { |record| record.active? && record.expired?(stale_minutes) }.map do |record|
          record.notes? ? orphan(record) : drop(record)
          record
        end
      end

      # Write a line into a lock this session holds, so that a machine coming
      # back up has something better than the diff to work out where it was.
      #
      # @param path [String]
      # @param text [String]
      # @return [Result]
      def note(path, text)
        scope = Scope.parse(path, tree: tree)
        record = store.find(scope)
        return result(:not_found, []) if record.nil?
        return result(:refused, [record]) unless record.held_by?(identity)

        updated = record.note(text)
        store.update(updated)
        result(:noted, [updated])
      end

      # Take an interrupted lock back, notes and all.
      #
      # Inside the store's mutex, because the check and the write are two
      # steps: two sessions resuming one orphan would otherwise both find it
      # interrupted, both write themselves in, and both report :resumed.
      #
      # @param path [String]
      # @return [Result]
      def resume(path)
        scope = Scope.parse(path, tree: tree)
        store.synchronize do
          record = store.find(scope)
          next result(:not_found, []) if record.nil? || record.active?

          adopted = record.with(status: Record::ACTIVE, updated_at: Time.now.utc.iso8601, **claim)
          store.update(adopted)
          result(:resumed, [adopted])
        end
      end

      private

      # The critical section of #acquire: the scan, and the write it justifies.
      #
      # @param scope [Scope]
      # @param intent [String]
      # @return [Result]
      def take(scope, intent)
        reap
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

        # Only this session's own lock covers it. Taking a second lock inside
        # your own would leave a stale one behind on release. A parent's lock
        # does not count: a child that stopped there recorded nothing, and
        # two siblings both "acquired" the same file.
        return result(:already_mine, own) if own.any?

        interrupted(scope)
      end

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

      # Who this session is, as a lock records it.
      #
      # @return [Hash]
      def claim
        evidence = identity.evidence
        { agent_id: identity.id, parent_agent_id: identity.parent_id,
          pid: evidence[:pid], started: evidence[:started], host: evidence[:host] }
      end

      # Freezing happens after the claim is won, never before. Flagging files
      # first and then losing the race would leave a tree full of unwritable
      # files that no lock admits to having frozen, which is the one failure
      # this whole feature is supposed to prevent.
      #
      # @param record [Record] the lock, already created
      # @return [Result]
      def enforce_on(record, scope, force:)
        wanted = Freeze.matches(scope, tree)
        frozen = Freeze.apply(wanted, tree: tree, force: force)
        updated = record.with(frozen_paths: frozen)
        store.update(updated)

        result(:acquired, [updated], freeze_shortfall(wanted, frozen))
      rescue Freeze::TooBroad
        # The lock stands; the freeze does not. Undoing the claim here would
        # be a second surprise on top of the first.
        drop(record)
        raise
      end

      # @return [String, nil] said only when the filesystem refused some of it
      def freeze_shortfall(wanted, frozen)
        missed = wanted.size - frozen.size
        return nil if missed.zero?

        "could not freeze #{missed} of #{wanted.size} file(s); the lock still stands"
      end

      # Orphaned locks are left out: they carry the notes of a session that
      # died, which is information rather than a claim, and a machine that
      # rebooted should not lock its owner out of their own checkout.
      #
      # @return [Array<Record>]
      def conflicts(scope)
        store.all.select do |record|
          record.active? && record.tree == tree.root && record.scope_object.conflicts_with?(scope)
        end
      end

      # @param record [Record]
      def orphan(record)
        Freeze.clear(record.frozen_paths, tree: tree)
        store.update(record.with(status: Record::ORPHANED, frozen_paths: [], updated_at: Time.now.utc.iso8601))
      end

      def drop(record)
        Freeze.clear(record.frozen_paths, tree: tree)
        store.delete(record)
      end

      def result(status, records, message = nil) = Result.new(status:, records:, message:)
    end
  end
end

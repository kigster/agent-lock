# frozen_string_literal: true

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
        def code = %i[held refused not_found interrupted].include?(status) ? 1 : 0

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

      # @param path [String] a path or a glob
      # @param intent [String]
      # @param enforce [Boolean] also make the matched files unwritable
      # @param force [Boolean] freeze even a very wide scope
      # @return [Result]
      def acquire(path, intent: "unspecified", enforce: false, force: false)
        scope = Scope.parse(path, tree: tree)
        reap

        refusal = why_not(scope)
        return refusal if refusal

        record = build(scope, intent: intent, enforce: enforce, force: force)
        return result(:held, conflicts(scope)) unless store.create(record)

        result(:acquired, [record])
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

      # @param path [String]
      # @return [Result]
      def check(path)
        scope = Scope.parse(path, tree: tree)
        reap
        blocking, family = conflicts(scope).partition { |record| record.blocks?(identity) }
        return result(:held, blocking) if blocking.any?
        return result(:mine, family) if family.any?

        result(:free, [])
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
      # @param path [String]
      # @return [Result]
      def resume(path)
        scope = Scope.parse(path, tree: tree)
        record = store.find(scope)
        return result(:not_found, []) if record.nil? || record.active?

        adopted = record.with(status: Record::ACTIVE, updated_at: Time.now.utc.iso8601, **claim)
        store.update(adopted)
        result(:resumed, [adopted])
      end

      private

      # Everything standing between this session and the scope it asked for,
      # in the order the caller can do something about.
      #
      # @param scope [Scope]
      # @return [Result, nil] nil when the scope is there to be taken
      def why_not(scope)
        blocking, family = conflicts(scope).partition { |record| record.blocks?(identity) }
        return result(:held, blocking) if blocking.any?

        # Every record left overlaps this scope and belongs to this session or
        # its parent, so the scope is already covered. Taking a second lock
        # inside your own would leave a stale one behind on release.
        return result(:already_mine, family) if family.any?

        # An orphan sitting on this exact scope is somebody's interrupted work.
        # Overwriting it would take the only record of it, so say so and let
        # the caller choose `resume` or `break`.
        interrupted = store.find(scope)
        result(:interrupted, [interrupted]) if interrupted&.orphaned?
      end

      # Who this session is, as a lock records it.
      #
      # @return [Hash]
      def claim
        evidence = identity.evidence
        { agent_id: identity.id, parent_agent_id: identity.parent_id,
          pid: evidence[:pid], started: evidence[:started], host: evidence[:host] }
      end

      # @return [Record]
      def build(scope, intent:, enforce:, force:)
        record = Record.build(scope: scope, tree: tree, identity: identity, intent: intent)
        enforce ? record.with(frozen_paths: freeze_for(scope, force: force)) : record
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

      def freeze_for(scope, force:)
        raise Freeze::TooBroad, "--enforce needs macOS; this is #{RUBY_PLATFORM}" unless Freeze.supported?

        Freeze.apply(Freeze.matches(scope, tree), tree: tree, force: force)
      end

      def result(status, records, message = nil) = Result.new(status:, records:, message:)
    end
  end
end

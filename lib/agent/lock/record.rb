# frozen_string_literal: true

require_relative "process_info"
require_relative "scope"

require "yaml"
require "time"
require "digest"
require "socket"

module Agent
  module Lock
    # One lock, on disk.
    #
    # A markdown file with YAML front matter, rather than plain YAML, because
    # the interesting half of a lock is the sentence saying what the holder is
    # doing. An agent that finds a file locked can read that and decide whether
    # to wait or to work elsewhere; "occupied" tells it nothing. A human
    # opening the file in an editor sees the same thing.
    #
    #     ---
    #     agent_id: claude-9feca100
    #     scope: workflow/**
    #     pid: 69232
    #     ---
    #     Rewriting the installer's filter pair.
    class Record
      FIELDS = %i[id agent_id parent_agent_id scope tree worktree pid started host
                  created_at updated_at status frozen_paths].freeze

      ACTIVE = "active"
      ORPHANED = "orphaned"
      SEPARATOR = "---"
      NOTES_HEADING = "## Progress"

      attr_reader(*FIELDS, :intent, :path)

      class << self
        # @param scope [Scope]
        # @param tree [Tree]
        # @param identity [Identity]
        # @param intent [String]
        # @return [Record]
        def build(scope:, tree:, identity:, intent:)
          evidence = identity.evidence
          new(
            id: id_for(tree, scope), agent_id: identity.id, parent_agent_id: identity.parent_id,
            scope: scope.to_s, tree: tree.root, worktree: tree.worktree?,
            pid: evidence[:pid], started: evidence[:started], host: evidence[:host],
            created_at: Time.now.utc.iso8601, status: ACTIVE, frozen_paths: [], intent: intent
          )
        end

        # Derived from the tree and the scope so that a second run looking for
        # the same lock finds it without reading every file in the store.
        #
        # @return [String]
        def id_for(tree, scope)
          digest = Digest::SHA256.hexdigest("#{tree.root}\0#{scope}")[0, 8]
          "#{scope.slug}-#{digest}"
        end

        # @param path [String]
        # @return [Record, nil] nil for a file this gem did not write
        def read(path)
          parse(File.read(path), path: path)
        rescue Errno::ENOENT, Errno::EISDIR
          nil
        end

        # @param text [String] a lock document, from a file or from Redis
        # @return [Record, nil]
        def parse(text, path: nil)
          _, front, body = text.to_s.split(/^#{SEPARATOR}\s*$/, 3)
          data = YAML.safe_load(front.to_s, permitted_classes: [], aliases: false)
          return nil unless data.is_a?(Hash)

          new(**data.transform_keys(&:to_sym).slice(*FIELDS), intent: body.to_s.strip, path: path)
        rescue Psych::Exception, ArgumentError
          nil
        end
      end

      def initialize(intent: "", path: nil, **fields)
        FIELDS.each { |field| instance_variable_set(:"@#{field}", fields[field]) }
        @frozen_paths = Array(@frozen_paths)
        @intent = intent.to_s
        @path = path
      end

      # @param changes [Hash] fields to replace
      # @return [Record] a copy, since a record on disk is not edited in place
      def with(intent: self.intent, **changes)
        fields = FIELDS.to_h { |field| [field, public_send(field)] }
        self.class.new(**fields.merge(changes), intent: intent, path: path)
      end

      # @return [String] the file's whole content
      def to_markdown
        front = FIELDS.to_h { |field| [field.to_s, public_send(field)] }.compact
        "#{YAML.dump(front)}#{SEPARATOR}\n\n#{intent.strip}\n"
      end

      # @return [Boolean] the holder is gone, but the work it recorded is not
      def orphaned? = status == ORPHANED

      # @return [Boolean] a claim anybody has to respect. An orphaned lock is a
      #   message left for whoever comes next, not a claim, so it blocks nobody.
      def active? = !orphaned?

      # What the holder has written down since taking the lock.
      #
      # A lock outlives a reboot; the session that took it does not. Notes are
      # kept in the lock itself, with the same lifespan, so that coming back to
      # a tree after a crash is reading one file rather than guessing.
      #
      # @param text [String]
      # @return [Record] a copy carrying the note
      def note(text)
        body = notes? ? intent : "#{intent}\n\n#{NOTES_HEADING}"
        with(intent: "#{body}\n- #{Time.now.utc.iso8601} #{text.strip}", updated_at: Time.now.utc.iso8601)
      end

      # @return [Boolean] whether anything worth keeping was written down
      def notes? = intent.include?(NOTES_HEADING)

      # @return [Scope]
      def scope_object = @scope_object ||= Scope.new(scope)

      # Two different questions, deliberately not one.
      #
      # Ownership answers "may I release this, write notes in it, and does
      # `mine` list it": yes for my own locks and my sub-agents', never for my
      # parent's. A session cleaning up after itself has to be able to take
      # its children's locks with it, or a crashed sub-agent's claim outlives
      # everybody. The reverse is how a child's `release-all` used to drop the
      # umbrella its parent had just fanned out under.
      #
      # @param identity [Identity]
      # @return [Boolean]
      def held_by?(identity) = mine?(identity) || descendant_of?(identity)

      # Blocking answers "may I claim an overlapping scope": everything except
      # my own lock and my parent's. The one that matters is the sibling: two
      # sub-agents of one session, let loose in the same tree, are exactly the
      # pair this gem exists to keep apart, and treating the whole family as
      # one holder would let them write over each other freely.
      #
      # A child's lock blocks its parent too. The parent handed that scope out;
      # taking it back while the child is still in there is the same collision
      # from the other direction.
      #
      # @param identity [Identity]
      # @return [Boolean]
      def blocks?(identity) = !(mine?(identity) || ancestor_of?(identity))

      # @return [Boolean] the holder's process is still running, on this host
      def alive?
        return true unless same_host?

        ProcessInfo.alive?(pid, started: started)
      end

      # A lock nobody can prove is dead, and nobody has touched in a long time.
      # The liveness check answers for a session that crashed on this machine;
      # this answers for one that cannot be checked at all.
      #
      # @param minutes [Integer]
      # @return [Boolean]
      def expired?(minutes)
        return true if same_host? && !alive?
        return false if created_at.nil?

        Time.now.utc - Time.parse(created_at) > minutes * 60
      rescue ArgumentError
        false
      end

      # A claim still standing, whose holder has not touched it in longer than
      # anybody should need. Reported, never acted on: the holder may be alive
      # and simply slow, so breaking it is a decision somebody announces.
      #
      # @param minutes [Integer]
      # @return [Boolean]
      def stale?(minutes)
        touched = updated_at || created_at
        return false if orphaned? || touched.nil?

        Time.now.utc - Time.parse(touched) > minutes * 60
      rescue ArgumentError
        false
      end

      # @return [String] one line, for a listing
      def summary
        where = worktree ? "#{tree} (worktree)" : tree
        "#{scope}\t#{agent_id}\t#{created_at}\t#{where}"
      end

      private

      def mine?(identity) = agent_id == identity.id

      # The lock belongs to the session that spawned this one.
      def ancestor_of?(identity) = !identity.parent_id.nil? && agent_id == identity.parent_id

      # The lock belongs to a sub-agent this session spawned.
      def descendant_of?(identity) = !parent_agent_id.nil? && parent_agent_id == identity.id

      def same_host? = host.nil? || host == Socket.gethostname
    end
  end
end

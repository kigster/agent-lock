# frozen_string_literal: true

require_relative "process_info"
require_relative "scope"
require_relative "tree"

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
      # The front-matter keys, in the order they are written. Each one is
      # also a reader on the record.
      FIELDS = %i[id agent_id parent_agent_id scope tree repo branch worktree pid started host
                  created_at updated_at status frozen_paths].freeze

      # The status of a live claim.
      ACTIVE = "active"

      # The status of a lock whose holder died with notes in it: it blocks
      # nobody, but is kept until somebody resumes or breaks it.
      ORPHANED = "orphaned"

      # What fences the YAML front matter off from the body.
      SEPARATOR = "---"

      # The heading `note` appends under. Its presence is what makes a dead
      # holder's lock worth orphaning rather than deleting.
      NOTES_HEADING = "## Progress"

      # @!attribute [r] id
      #   @return [String] `<scope slug>-<digest>`, the same on every clone of a branch
      # @!attribute [r] agent_id
      #   @return [String] who holds it, see {Identity#id}
      # @!attribute [r] parent_agent_id
      #   @return [String, nil] the session that spawned the holder, if any
      # @!attribute [r] scope
      #   @return [String] the normalized glob, relative to the tree root
      # @!attribute [r] tree
      #   @return [String] the absolute root of the checkout that took it
      # @!attribute [r] repo
      #   @return [String, nil] the repository it was taken in, see {Tree#repo}
      # @!attribute [r] branch
      #   @return [String, nil] the branch it was taken on; nil on a detached HEAD
      # @!attribute [r] worktree
      #   @return [Boolean] whether the checkout was a linked worktree
      # @!attribute [r] pid
      #   @return [Integer, nil] the holder's session process, used to reap it
      # @!attribute [r] started
      #   @return [String, nil] that process's start time, so a recycled pid is not mistaken for it
      # @!attribute [r] host
      #   @return [String, nil] the machine the holder runs on
      # @!attribute [r] created_at
      #   @return [String] ISO 8601, UTC
      # @!attribute [r] updated_at
      #   @return [String, nil] ISO 8601, UTC, the last note or resume
      # @!attribute [r] status
      #   @return [String] {ACTIVE} or {ORPHANED}
      # @!attribute [r] frozen_paths
      #   @return [Array<String>] files `--enforce` froze, so a release can thaw them
      FIELDS.each { |field| attr_reader(field) }

      # @return [String] the body: what the holder is doing, then its notes
      attr_reader :intent

      # @return [String, nil] the file it was read from; nil outside the file store
      attr_reader :path

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
            scope: scope.to_s, tree: tree.root, repo: tree.repo, branch: tree.branch, worktree: tree.worktree?,
            pid: evidence[:pid], started: evidence[:started], host: evidence[:host],
            created_at: Time.now.utc.iso8601, status: ACTIVE, frozen_paths: [], intent: intent
          )
        end

        # Derived from the tree's lock key and the scope so that a second run
        # looking for the same lock finds it without reading every file in the
        # store, and so that two checkouts of one branch, on any machine, are
        # after the same id and cannot both win it.
        #
        # @param tree [Tree]
        # @param scope [Scope]
        # @return [String]
        def id_for(tree, scope)
          digest = Digest::SHA256.hexdigest("#{tree.lock_key}\0#{scope}")[0, 8]
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
        # @param path [String, nil] the file it was read from, for the file store
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

      # @param intent [String] the body: what the holder is doing, plus its notes
      # @param path [String, nil] the file it was read from, for the file store
      # @param fields [Hash{Symbol => Object}] any of {FIELDS}
      def initialize(intent: "", path: nil, **fields)
        FIELDS.each { |field| instance_variable_set(:"@#{field}", fields[field]) }
        @frozen_paths = Array(@frozen_paths)
        @intent = intent.to_s
        @path = path
      end

      # @param intent [String] the body, unchanged unless given
      # @param changes [Hash] fields to replace
      # @return [Record] a copy, since a record on disk is not edited in place
      def with(intent: self.intent, **changes)
        fields = FIELDS.to_h { |field| [field, public_send(field)] }
        self.class.new(**fields, **changes, intent: intent, path: path)
      end

      # @return [String] the file's whole content
      def to_markdown
        front = FIELDS.to_h { |field| [field.to_s, public_send(field)] }.compact
        "#{YAML.dump(front)}#{SEPARATOR}\n\n#{intent.strip}\n"
      end

      # This orphan as a live claim again, held by `identity` on the branch
      # `tree` is on now, which need not be the one it was taken on. Its id
      # follows the branch, so the caller has to write it under the new id.
      #
      # @param tree [Tree]
      # @param scope [Scope]
      # @param identity [Identity]
      # @return [Record]
      def resumed(tree:, scope:, identity:)
        evidence = identity.evidence
        with(
          id: self.class.id_for(tree, scope), tree: tree.root, repo: tree.repo, branch: tree.branch,
          worktree: tree.worktree?, status: ACTIVE, updated_at: Time.now.utc.iso8601,
          agent_id: identity.id, parent_agent_id: identity.parent_id,
          pid: evidence[:pid], started: evidence[:started], host: evidence[:host]
        )
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

      # @return [String] see Tree#lock_key. A record written before `repo` and
      #   `branch` were kept has neither, and so falls back to its path on the
      #   host that wrote it, which no other host's key can equal.
      def lock_key = Tree.lock_key(repo: repo, branch: branch, root: tree, host: host)

      # Whether this lock is about the files a tree holds: the same repository
      # on the same branch, from anywhere, or this very checkout on this host,
      # whatever branch it was taken on, since switching branches does not
      # make the files on disk somebody else's.
      #
      # @param checkout [Tree]
      # @return [Boolean]
      def about?(checkout) = lock_key == checkout.lock_key || local_to?(checkout)

      # Whether this lock was taken in this very checkout, on this host. Only
      # then do its frozen paths name files here: the same relative path in
      # another checkout, or on another machine, is a different file.
      #
      # @param checkout [Tree]
      # @return [Boolean]
      def local_to?(checkout) = tree == checkout.root && same_host?

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

      # Whether the claim is void, so reaping it takes nothing from anybody.
      #
      # On this host the holder can be asked, and its answer is the only one
      # that counts: a live holder's lock is never expired, however old. Age
      # used to count here too, measured from `created_at`, so a session two
      # hours into a refactor lost its lock mid-edit and the next agent walked
      # straight in. A holder on another host cannot be asked, so time is all
      # there is, measured from its last write so that notes act as a
      # heartbeat.
      #
      # @param minutes [Integer] how long an unverifiable lock is trusted
      # @return [Boolean]
      def expired?(minutes) = same_host? ? !alive? : untouched_for?(minutes)

      # A claim still standing, whose holder has not touched it in longer than
      # anybody should need. Reported, never acted on: the holder may be alive
      # and simply slow, so breaking it is a decision somebody announces.
      #
      # @param minutes [Integer]
      # @return [Boolean]
      def stale?(minutes) = active? && untouched_for?(minutes)

      # @return [String] one line, for a listing
      def summary
        where = worktree ? "#{tree} (worktree)" : tree
        "#{scope}\t#{agent_id}\t#{created_at}\t#{where}"
      end

      private

      # @param identity [Identity]
      # @return [Boolean]
      def mine?(identity) = agent_id == identity.id

      # The lock belongs to the session that spawned this one.
      #
      # @param identity [Identity]
      # @return [Boolean]
      def ancestor_of?(identity) = !identity.parent_id.nil? && agent_id == identity.parent_id

      # The lock belongs to a sub-agent this session spawned.
      #
      # @param identity [Identity]
      # @return [Boolean]
      def descendant_of?(identity) = !parent_agent_id.nil? && parent_agent_id == identity.id

      # @return [Boolean] true too when the record names no host
      def same_host? = host.nil? || host == Socket.gethostname

      # A lock with no readable timestamp is left alone rather than guessed
      # at: reaping on a parse error would delete live claims.
      #
      # @param minutes [Integer]
      # @return [Boolean]
      def untouched_for?(minutes)
        touched = updated_at || created_at
        return false if touched.nil?

        Time.now.utc - Time.parse(touched) > minutes * 60
      rescue ArgumentError
        false
      end
    end
  end
end

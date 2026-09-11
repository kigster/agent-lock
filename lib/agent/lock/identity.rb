# frozen_string_literal: true

require "etc"
require "socket"
require "digest"

module Agent
  module Lock
    # Who is asking, and whether they are still around.
    #
    # A lock is worthless unless the holder gives the same answer every time it
    # is asked. The obvious answer, this process's own pid, is the wrong one: an
    # agent harness runs each command in a shell of its own, so a lock acquired
    # by one invocation could never be released by the next. The identity has to
    # belong to the session, not to the process that happens to be speaking for
    # it right now.
    #
    # In order of preference:
    #
    #   AGENT_ID             what a human or a harness set on purpose
    #   CLAUDE_SESSION_ID    the session, which survives --resume
    #   fingerprint          the first ancestor process that is not a shell
    #
    # The fingerprint is the fallback that needs explaining. Walking up from
    # this process, the shells are throwaway and the thing above them is not:
    # the `claude` or `codex` process driving the session, or the terminal a
    # human is typing in. Its pid and start time, hashed, are stable for as
    # long as that session lives and different for anybody else's.
    class Identity
      SHELLS = %w[sh bash zsh ksh csh tcsh fish dash].freeze
      MAX_HOPS = 10

      class << self
        # Deliberately not memoized. A forked CLI computes this once and dies,
        # but the same code runs inside a long-lived process during the specs
        # and inside any harness that loads the library, where a cached answer
        # would outlive the environment it was computed from.
        #
        # @return [Identity]
        def current = new

        # The ancestry walk, on the other hand, cannot change while this
        # process lives, and it costs two `ps` calls per hop.
        #
        # @return [Integer]
        def session_pid = @session_pid ||= yield
      end

      # @param env [Hash]
      def initialize(env: ENV)
        @env = env
      end

      # @return [String] the holder name written into a lock
      def id
        @id ||= explicit || session || fingerprint
      end

      # The session that spawned this one: AGENT_PARENT_ID when a harness says
      # so, and otherwise inferred.
      #
      # The inference exists because Claude Code runs a sub-agent inside its
      # parent's own process and sets nothing to tell them apart, so without it
      # every sub-agent resolved to its parent's fingerprint and none of them
      # could ever block another. A sub-agent's one distinguishing mark is the
      # AGENT_ID it was told to use. When that differs from what this session
      # would answer to without it, the session is, by elimination, the
      # parent.
      #
      # @return [String, nil]
      def parent_id
        return @parent_id if defined?(@parent_id)

        @parent_id = declared_parent || inferred_parent
      end

      # Where #id came from, so a session can check what it is being taken for
      # before a lock is written under the wrong name.
      #
      # @return [Symbol] :explicit, :session or :fingerprint
      def source
        return :explicit if explicit
        return :session if session

        :fingerprint
      end

      # Where #parent_id came from. An inferred parent is a guess a human may
      # want to overrule with AGENT_PARENT_ID, so it is reported as one.
      #
      # @return [Symbol, nil] :explicit, :inferred, or nil when there is no parent
      def parent_source
        return :explicit if declared_parent

        :inferred if parent_id
      end

      # Evidence, not identity: enough to ask later whether the holder is still
      # running. The pid alone is not enough, since pids are reused, and the
      # host matters because a lock store can be on a shared or synced volume.
      #
      # @return [Hash{Symbol => Object}]
      def evidence
        { pid: session_pid, started: ProcessInfo.started_at(session_pid), host: Socket.gethostname }
      end

      private

      def explicit = presence(@env["AGENT_ID"])

      def declared_parent = presence(@env["AGENT_PARENT_ID"])

      # What this session answers to when nobody names it, which is the
      # orchestrator's id. The session id counts as well as the fingerprint:
      # under a harness that exports CLAUDE_SESSION_ID the orchestrator's locks
      # carry that, and a parent inferred from the fingerprint alone would
      # match none of them. A session that named itself by its own fingerprint
      # is not its own child.
      #
      # @return [String, nil]
      def inferred_parent
        return nil unless explicit

        own = session || fingerprint
        own unless own == explicit
      end

      def session
        value = presence(@env["CLAUDE_SESSION_ID"])
        value && "session-#{value[0, 8]}"
      end

      # @return [String] e.g. "claude-1f4c8a02"
      def fingerprint
        pid = session_pid
        name = ProcessInfo.command(pid) || "agent"
        digest = Digest::SHA256.hexdigest(
          [pid, ProcessInfo.started_at(pid), Etc.getpwuid(::Process.uid)&.name, Socket.gethostname].join("|")
        )
        "#{name}-#{digest[0, 8]}"
      end

      # The first ancestor that is not a shell, which is the process that lasts
      # as long as the session does.
      #
      # @return [Integer]
      def session_pid
        self.class.session_pid do
          pid = ::Process.ppid
          MAX_HOPS.times do
            name = ProcessInfo.command(pid)
            break unless name && SHELLS.include?(name.delete_prefix("-"))

            parent = ProcessInfo.parent_of(pid)
            break unless parent && parent > 1

            pid = parent
          end
          pid
        end
      end

      def presence(value) = value.nil? || value.strip.empty? ? nil : value.strip
    end
  end
end

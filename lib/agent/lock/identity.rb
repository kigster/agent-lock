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

      # The session that spawned this one, when a harness says so. A subagent
      # working inside its parent's lock is not a second agent.
      #
      # @return [String, nil]
      def parent_id = presence(@env["AGENT_PARENT_ID"])

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

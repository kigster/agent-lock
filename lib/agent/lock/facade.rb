# frozen_string_literal: true

require_relative "facade/backend"
require_relative "facade/session"
require_relative "facade/refusal"
require_relative "facade/memo"

module Agent
  # {Facade} and the process-wide facades {.local} and {.distributed}.
  module Lock
    # Every `alock` command as a method, run in this process, so a caller
    # pays for no new Ruby process per call. (`git` and `ps` still run, as
    # they do under the CLI, to find the checkout and check holders.)
    #
    # One facade is one locker. It picks its backend when it is built and
    # keeps it, so every thread calling it takes locks in the same store. A
    # second facade with another `redis_url` is a separate locker. Building
    # one never touches {Agent::Lock.local} or {Agent::Lock.distributed}.
    #
    # Thread-safe: a facade is frozen, and each call builds its own
    # {Manager}, so threads share nothing but the store, whose mutex
    # serializes the writes.
    #
    # A lock method returns the {Manager::Result} on success. Where the CLI
    # would print a refusal on stderr, it raises {Refused}, whose `result` is
    # the same {Manager::Result}. `:not_found` from {#release},
    # {#break_lock} and {#resume} is returned, although the CLI exits 1 on
    # it: nothing was there, so nothing was refused.
    #
    # Every lock method also takes these keywords, which override the
    # facade's defaults for that one call:
    #
    # - `dir:` [String] a directory inside the checkout (default: the current one)
    # - `agent_id:` [String] who holds the lock
    # - `parent_id:` [String] that holder's parent session
    # - `stale_minutes:` [Integer] when an unverifiable lock counts as stale
    #
    # The checkout's backend marker binds a facade just as it binds `alock`:
    # a facade claims a virgin checkout for its backend, and raises
    # {Store::Mismatch} in one already claimed for the other, so a facade
    # and the CLI can never take the same scope in two stores.
    #
    # @example File store, signed by a sub-agent
    #   locks = Agent::Lock.local
    #   locks.acquire("lib/**", "rewriting billing", agent_id: "luke-backend")
    #
    # @example Redis, falling back to the file store when it does not answer
    #   locks = Agent::Lock::Facade.new(
    #     strategies: %w[redis file],
    #     redis_url: ENV.fetch("REDIS_URL", "redis://localhost:6379")
    #   )
    class Facade
      # Tried in this order when the caller does not pass `strategies`.
      DEFAULT_STRATEGIES = %w[redis file].freeze

      # Used when `redis_url` is omitted and `REDIS_URL` is unset.
      DEFAULT_REDIS_URL = "redis://localhost:6379"

      # @param strategies [Array<String, Symbol>] backends to try, in order:
      #   `redis`, and `file` (or `filesystem`)
      # @param redis_url [String, nil] defaults to `REDIS_URL`, then {DEFAULT_REDIS_URL}
      # @param agent_id [String, nil] signs locks when a call does not name its own
      # @param parent_id [String, nil] that holder's parent, likewise
      # @param stale_minutes [Integer, nil] nil reads `AGENT_LOCK_STALE_MINUTES`
      # @raise [RedisUnavailableError] when no strategy but `redis` is left and it does not answer
      # @raise [ArgumentError] when `strategies` is empty or names an unknown backend
      def initialize(strategies: DEFAULT_STRATEGIES, redis_url: nil, agent_id: nil, parent_id: nil,
                     stale_minutes: nil)
        @backend = Backend.new(strategies:, redis_url: redis_url || ENV.fetch("REDIS_URL", DEFAULT_REDIS_URL))
        @session = Session.new(@backend, agent_id:, parent_id:, stale_minutes:)
        freeze
      end

      # @return [String] "redis" or "file", chosen once at construction
      def backend_name = @backend.name

      # @return [String] the Redis URL this facade was given, used or not
      def redis_url = @backend.redis_url

      # `alock acquire`: claim a scope before writing in it.
      #
      # @param scope [String] a path, a directory, or a glob such as `lib/**`
      # @param intent [String, nil] what the holder is about to do
      # @param enforce [Boolean] also freeze the matched files (macOS only)
      # @param allow_wide [Boolean] let `enforce` freeze more than {Freeze::LIMIT} files
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`
      # @return [Manager::Result] `:acquired`, or `:already_mine` when a lock of yours covers it
      # @raise [Refused] held by another agent, interrupted work, or exactly your parent's scope
      # @raise [Scope::Invalid] when the scope is empty or outside the checkout
      # @raise [Freeze::TooBroad] when `enforce` exceeds the limit without `allow_wide`
      def acquire(scope, intent = nil, enforce: false, allow_wide: false, **session)
        result = @session.manager(**session).acquire(scope, intent: intent || "unspecified", enforce:, wide: allow_wide)
        Refusal.check!(result, scope:)
      end

      # `alock release`.
      #
      # @param scope [String]
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`
      # @return [Manager::Result] `:released`, or `:not_found` when nothing is locked there
      # @raise [Refused] when another agent holds it
      def release(scope, **session) = Refusal.check!(@session.manager(**session).release(scope), scope:)

      # `alock check`: may I write here?
      #
      # @param scope [String]
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`
      # @return [Manager::Result] `:free`, or `:mine`
      # @raise [Refused] when another agent holds an overlapping scope
      def check(scope, **session) = Refusal.check!(@session.manager(**session).check(scope), scope:)

      # `alock list`.
      #
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`
      # @return [Manager::Result] every lock in this facade's store
      def list(**session) = @session.manager(**session).list

      # `alock mine`.
      #
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`
      # @return [Manager::Result] locks held by this identity and its sub-agents
      def mine(**session) = @session.manager(**session).mine

      # `alock release-all`.
      #
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`
      # @return [Manager::Result] what was released
      def release_all(**session) = @session.manager(**session).release_all

      # `alock break`: drop somebody else's lock. Announce it first. Never
      # raises a refusal: breaking a free scope returns `:not_found`.
      #
      # @param scope [String]
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`
      # @return [Manager::Result] `:broken`, or `:not_found`
      def break_lock(scope, **session) = @session.manager(**session).break_lock(scope)

      # `alock note`: leave a note on a lock you hold.
      #
      # @param scope [String]
      # @param text [String]
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`
      # @return [Manager::Result] `:noted`
      # @raise [Refused] when nothing is locked there, or another agent holds it
      def note(scope, text, **session)
        Refusal.check!(@session.manager(**session).note(scope, text), scope:, also: %i[not_found])
      end

      # `alock resume`: take back interrupted work, notes and all.
      #
      # @param scope [String]
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`
      # @return [Manager::Result] `:resumed`, or `:not_found` when there is nothing to resume
      # @raise [Refused] when another agent holds an overlapping scope, or the
      #   interrupted work could not be moved onto this scope
      def resume(scope, **session) = Refusal.check!(@session.manager(**session).resume(scope), scope:)

      # `alock whoami`: who a lock taken through this facade would name.
      #
      # @param agent_id [String, nil]
      # @param parent_id [String, nil]
      # @return [Identity]
      def whoami(agent_id: nil, parent_id: nil) = @session.identity(agent_id:, parent_id:)

      # `alock skills path`.
      #
      # @return [String] the directory of the bundled skill
      def skills_path = Skill.source

      # `alock skills install`.
      #
      # @param into [String, nil] skills directory; wins over `agent` when both are given
      # @param agent [String, nil] the CLI's `--for`: `claude` installs into ~/.claude/skills,
      #   anything else into ~/.agents/skills
      # @param overwrite [Boolean] replace an installed copy that differs
      # @return [Skill::Result] `:installed` or `:current`
      # @raise [Refused] when the installed copy differs, or is a symlink
      def skills_install(into: nil, agent: nil, overwrite: false)
        Refusal.check!(Skill.new(into: into || Skill.default_into(agent)).install(overwrite:))
      end

      # `alock version`.
      #
      # @return [String] {VERSION}
      def version = VERSION
    end

    # Built on first use, once per process; see {.local} and {.distributed}.
    LOCAL_FACADE = Facade::Memo.new { Facade.new(strategies: %w[file]) }
    DISTRIBUTED_FACADE = Facade::Memo.new { Facade.new(strategies: %w[redis]) }
    private_constant :LOCAL_FACADE, :DISTRIBUTED_FACADE

    class << self
      # The process-wide file-store facade, built on first use. Thread-safe,
      # and independent of {.distributed} and of every {Facade.new}.
      #
      # @return [Facade]
      def local = LOCAL_FACADE.value

      # The process-wide Redis facade, built on first use from `REDIS_URL`
      # (or {Facade::DEFAULT_REDIS_URL}). Thread-safe. A failed build is not
      # kept: the next call tries Redis again.
      #
      # @return [Facade]
      # @raise [RedisUnavailableError] when that Redis does not answer
      def distributed = DISTRIBUTED_FACADE.value

      # A new facade, defaulting like `alock`: Redis when it answers, the
      # file store when it does not. Never memoized.
      #
      # @param strategies [Array<String, Symbol>] see {Facade#initialize}
      # @param redis_url [String, nil] see {Facade#initialize}
      # @param agent_id [String, nil] see {Facade#initialize}
      # @param parent_id [String, nil] see {Facade#initialize}
      # @param stale_minutes [Integer, nil] see {Facade#initialize}
      # @return [Facade]
      def facade(strategies: Facade::DEFAULT_STRATEGIES, redis_url: nil, agent_id: nil, parent_id: nil,
                 stale_minutes: nil)
        Facade.new(strategies:, redis_url:, agent_id:, parent_id:, stale_minutes:)
      end

      # Forget {.local} and {.distributed}, so the next call builds each anew.
      # For tests, and for a process whose `REDIS_URL` changed.
      #
      # @return [void]
      def reset_facades!
        LOCAL_FACADE.reset
        DISTRIBUTED_FACADE.reset
      end
    end
  end
end

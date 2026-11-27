# frozen_string_literal: true

require_relative "facade/backend"
require_relative "facade/session"
require_relative "facade/refusal"
require_relative "facade/memo"
require_relative "facade/async"

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
    # - `session_name:` [String] the session's name, tied to no process
    #
    # The checkout's backend marker binds a facade just as it binds `alock`:
    # a facade claims a virgin checkout for its backend, and raises
    # {Store::Mismatch} in one already claimed for the other, so a facade
    # and the CLI can never take the same scope in two stores.
    #
    # `async: true` adds {#async}, which runs any lock method on
    # concurrent-ruby's I/O pool and returns a `Concurrent::Promises::Future`:
    # `value!` is the result or re-raises, `value` is nil when the call raised
    # and `reason` holds why. Arguments, keywords and blocks pass through as
    # on a direct call, and direct calls stay synchronous. concurrent-ruby is
    # not a dependency of this gem; add it to the Gemfile to use this.
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

      # Used when `redis_url` is omitted and neither `AGENT_LOCK_REDIS_URL`
      # nor `REDIS_URL` is set.
      DEFAULT_REDIS_URL = "redis://localhost:6379"

      # The Redis a facade uses, by the rule `alock` follows: what the
      # caller named, then `AGENT_LOCK_REDIS_URL`, then `REDIS_URL`.
      #
      # @param redis_url [String, nil] the caller's
      # @return [String]
      def self.redis_url(redis_url = nil)
        redis_url || Store.named_redis_url || ENV.fetch("REDIS_URL", DEFAULT_REDIS_URL)
      end

      # @param strategies [Array<String, Symbol>] backends to try, in order:
      #   `redis`, and `file` (or `filesystem`)
      # @param redis_url [String, nil] defaults as {.redis_url} says:
      #   `AGENT_LOCK_REDIS_URL`, then `REDIS_URL`, then {DEFAULT_REDIS_URL}
      # @param async [Boolean] offer {#async}; needs the concurrent-ruby gem
      # @param defaults [Hash] what a call uses when it does not say:
      # @option defaults [String] :agent_id signs locks when a call does not name its own
      # @option defaults [String] :parent_id that holder's parent, likewise
      # @option defaults [Integer] :stale_minutes nil reads `AGENT_LOCK_STALE_MINUTES`
      # @option defaults [Symbol] :holder `:process` (default) ties a lock's
      #   liveness to this Ruby process, so locks left by a crashed host are
      #   reaped; `:session` ties it to the first non-shell ancestor, as `alock` does
      # @option defaults [String] :session_name the session's name, such as a
      #   plan id, in place of `CLAUDE_SESSION_ID` and the fingerprint, and
      #   in place of `holder:`. Its locks are tied to no process: they
      #   survive a restart and lapse when untouched for `stale_minutes`
      # @raise [RedisUnavailableError] when no strategy but `redis` is left and it does not answer
      # @raise [ArgumentError] when `strategies` is empty or names an unknown
      #   backend, `holder` is not `:process` or `:session` or is given
      #   beside `session_name`, or a default is not one of those five
      # @raise [LoadError] when `async` is true and concurrent-ruby is not installed
      def initialize(strategies: DEFAULT_STRATEGIES, redis_url: nil, async: false, **defaults)
        @backend = Backend.new(strategies:, redis_url: Facade.redis_url(redis_url))
        @session = Session.new(@backend, **defaults)
        @async = async ? Async.tap(&:load!).new(self) : nil
        freeze
      end

      # @return [String] "redis" or "file", chosen once at construction
      def backend_name = @backend.name

      # @return [String] the Redis URL this facade was given, used or not
      def redis_url = @backend.redis_url

      # The lock methods again, each returning a future instead of waiting.
      #
      # @example
      #   locks = Agent::Lock::Facade.new(strategies: %w[file], async: true)
      #   future = locks.async.acquire("lib/**", "rewriting billing", agent_id: "luke-backend")
      #   future.value!.status # => :acquired
      #
      # @return [Async]
      # @raise [ArgumentError] when the facade was built without `async: true`
      def async = @async || raise(ArgumentError, "build the facade with async: true to call #async")

      # `alock acquire`: claim a scope before writing in it.
      #
      # With a block, yields the {Manager::Result} and returns the block's
      # value. The lock is released afterwards only when this call took it
      # (`:acquired`). `:already_mine` yields and leaves the lock you already
      # held, so a nested block does not drop the outer one. A refusal raises
      # before the block runs. An exception from the block releases, then
      # propagates. When that release is itself refused (somebody broke the
      # lock and took the scope while the block ran), the block's exception
      # still wins: replacing it with the release's {Refused} hid the bug
      # the caller actually had.
      #
      # @param scope [String] a path, a directory, or a glob such as `lib/**`
      # @param intent [String, nil] what the holder is about to do
      # @param enforce [Boolean] also freeze the matched files (macOS only)
      # @param allow_wide [Boolean] let `enforce` freeze more than {Freeze::LIMIT} files
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`,
      #   `session_name:`
      # @yieldparam result [Manager::Result] `:acquired`, or `:already_mine`
      # @return [Manager::Result] without a block: `:acquired`, or `:already_mine`
      # @return [Object] with a block: the block's value
      # @raise [Refused] held by another agent, interrupted work, or exactly your parent's scope
      # @raise [Scope::Invalid] when the scope is empty or outside the checkout
      # @raise [Freeze::TooBroad] when `enforce` exceeds the limit without `allow_wide`
      def acquire(scope, intent = nil, enforce: false, allow_wide: false, **session)
        result = Refusal.check!(
          @session.manager(**session).acquire(scope, intent: intent || "unspecified", enforce:, wide: allow_wide),
          scope:
        )
        return result unless block_given?
        return yield(result) unless result.status == :acquired

        within(scope, session) { yield result }
      end

      # `alock release`.
      #
      # @param scope [String]
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`,
      #   `session_name:`
      # @return [Manager::Result] `:released`, or `:not_found` when nothing is locked there
      # @raise [Refused] when another agent holds it
      def release(scope, **session) = Refusal.check!(@session.manager(**session).release(scope), scope:)

      # `alock check`: may I write here?
      #
      # @param scope [String]
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`,
      #   `session_name:`
      # @return [Manager::Result] `:free`, or `:mine`
      # @raise [Refused] when another agent holds an overlapping scope
      def check(scope, **session) = Refusal.check!(@session.manager(**session).check(scope), scope:)

      # `alock list`.
      #
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`,
      #   `session_name:`
      # @return [Manager::Result] every lock in this facade's store
      def list(**session) = @session.manager(**session).list

      # `alock mine`.
      #
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`,
      #   `session_name:`
      # @return [Manager::Result] locks held by this identity and its sub-agents
      def mine(**session) = @session.manager(**session).mine

      # `alock release-all`.
      #
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`,
      #   `session_name:`
      # @return [Manager::Result] what was released
      def release_all(**session) = @session.manager(**session).release_all

      # `alock break`: drop somebody else's lock. Announce it first. Never
      # raises a refusal: breaking a free scope returns `:not_found`.
      #
      # @param scope [String]
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`,
      #   `session_name:`
      # @return [Manager::Result] `:broken`, or `:not_found`
      def break_lock(scope, **session) = @session.manager(**session).break_lock(scope)

      # `alock note`: leave a note on a lock you hold.
      #
      # @param scope [String]
      # @param text [String]
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`,
      #   `session_name:`
      # @return [Manager::Result] `:noted`
      # @raise [Refused] when nothing is locked there, or another agent holds it
      def note(scope, text, **session)
        Refusal.check!(@session.manager(**session).note(scope, text), scope:, also: %i[not_found])
      end

      # `alock resume`: take back interrupted work, notes and all.
      #
      # @param scope [String]
      # @param session [Hash] `dir:`, `agent_id:`, `parent_id:`, `stale_minutes:`,
      #   `session_name:`
      # @return [Manager::Result] `:resumed`, or `:not_found` when there is nothing to resume
      # @raise [Refused] when another agent holds an overlapping scope, or the
      #   interrupted work could not be moved onto this scope
      def resume(scope, **session) = Refusal.check!(@session.manager(**session).resume(scope), scope:)

      # `alock whoami`: who a lock taken through this facade would name.
      #
      # @param session [Hash] `agent_id:`, `parent_id:`, `session_name:`
      # @return [Identity]
      def whoami(**session) = @session.identity(**session)

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

      private

      # Run the block of an {#acquire} that took the lock, then release it.
      # `ensure`, so a `break`, `throw` or exception still releases. Only a
      # block that finished lets a refused release raise; otherwise the
      # refusal is swallowed and whatever was unwinding carries on.
      #
      # @param scope [String]
      # @param session [Hash]
      # @return [Object] the block's value
      def within(scope, session)
        finished = false
        value = yield
        finished = true
        value
      ensure
        begin
          release(scope, **session)
        rescue Refused
          raise if finished
        end
      end
    end

    # Built on first use, once per process; see {.local} and {.distributed}.
    LOCAL_FACADE = Facade::Memo.new { Facade.new(strategies: %w[file]) }
    # One per Redis URL, each built once.
    DISTRIBUTED_FACADES = Facade::Memo.new { {} }
    DISTRIBUTED_MUTEX = Mutex.new
    private_constant :LOCAL_FACADE, :DISTRIBUTED_FACADES, :DISTRIBUTED_MUTEX

    class << self
      # The process-wide file-store facade, built on first use. Thread-safe,
      # and independent of {.distributed} and of every {Facade.new}.
      #
      # @return [Facade]
      def local = LOCAL_FACADE.value

      # The process-wide Redis facade for one Redis, built on first use and
      # kept per URL, so a host whose Redis comes from its own flag or
      # config file gets the same locker on every call. Thread-safe. A
      # failed build is not kept: the next call tries Redis again.
      #
      # @param redis_url [String, nil] nil resolves as {Facade.redis_url}
      #   says: `AGENT_LOCK_REDIS_URL`, then `REDIS_URL`, then the default
      # @return [Facade]
      # @raise [RedisUnavailableError] when that Redis does not answer
      def distributed(redis_url: nil)
        url = Facade.redis_url(redis_url)
        DISTRIBUTED_MUTEX.synchronize do
          DISTRIBUTED_FACADES.value[url] ||= Facade.new(strategies: %w[redis], redis_url: url)
        end
      end

      # A new facade, defaulting like `alock`: Redis when it answers, the
      # file store when it does not. Never memoized.
      #
      # @param strategies [Array<String, Symbol>] see {Facade#initialize}
      # @param redis_url [String, nil] see {Facade#initialize}
      # @param async [Boolean] see {Facade#initialize}
      # @param defaults [Hash] `agent_id:`, `parent_id:`, `stale_minutes:`,
      #   `holder:`, `session_name:`; see {Facade#initialize}
      # @return [Facade]
      def facade(strategies: Facade::DEFAULT_STRATEGIES, redis_url: nil, async: false, **defaults)
        Facade.new(strategies:, redis_url:, async:, **defaults)
      end

      # Forget {.local} and {.distributed}, so the next call builds each anew.
      # For tests. A process whose `REDIS_URL` changed needs no reset: the
      # new URL is a new facade.
      #
      # @return [void]
      def reset_facades!
        LOCAL_FACADE.reset
        DISTRIBUTED_FACADES.reset
      end
    end
  end
end

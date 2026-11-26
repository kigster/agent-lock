# frozen_string_literal: true

require_relative "facade/backend"
require_relative "facade/runner"

module Agent
  # In-process access to the lock commands. {Facade} runs each one.
  module Lock
    # The lock commands, called in this process instead of through `alock`.
    #
    # One facade is one locker. It picks a backend when it is built and
    # stays on it, so every thread that calls it takes locks in the same
    # store. A second facade with another `redis_url` is a different locker.
    # Building one does not change {Agent::Lock.local} or
    # {Agent::Lock.distributed}.
    #
    # Each method runs the command of the same name. A refusal that command
    # would print on stderr is raised as {Refused}, and the message is that
    # text. A result the command prints on stdout comes back as a
    # {Manager::Result}, a {Skill::Result}, or a string.
    #
    # The facade does not read or write the tree's backend marker. Pass the
    # same strategies and Redis URL from every process that must see the
    # same locks.
    #
    # @example File store, named like a sub-agent
    #   locks = Agent::Lock.local
    #   locks.acquire("lib/**", "rewriting billing", agent_id: "luke")
    #
    # @example Redis, then the file store if that URL does not answer
    #   locks = Agent::Lock::Facade.new(
    #     strategies: %w[redis file],
    #     redis_url: ENV.fetch("REDIS_URL", "redis://localhost:6379")
    #   )
    class Facade
      # Tried in this order when the caller does not pass `strategies`.
      DEFAULT_STRATEGIES = %w[redis file].freeze

      # Used when `redis_url` is omitted and `REDIS_URL` is unset.
      DEFAULT_REDIS_URL = "redis://localhost:6379"

      # @return [String] "redis" or "file", chosen once at construction
      attr_reader :backend_name

      # @return [String] the Redis URL this facade was given
      attr_reader :redis_url

      # @param strategies [Array<String, Symbol>] tried in order. `file` and
      #   `filesystem` are the file store. `redis` is used when `redis_url` answers.
      # @param redis_url [String, nil] defaults to `REDIS_URL`, then {DEFAULT_REDIS_URL}
      # @param agent_id [String, nil] signs locks when a call does not pass its own
      # @param parent_id [String, nil]
      # @param stale_minutes [Integer, nil] nil reads `AGENT_LOCK_STALE_MINUTES`
      # @raise [RedisUnavailableError] when Redis is required and does not answer
      # @raise [ArgumentError] when `strategies` is empty or names an unknown backend
      def initialize(strategies: DEFAULT_STRATEGIES, redis_url: nil, agent_id: nil, parent_id: nil,
                     stale_minutes: nil)
        @redis_url = redis_url || ENV.fetch("REDIS_URL", DEFAULT_REDIS_URL)
        @backend = Backend.new(strategies: strategies, redis_url: @redis_url)
        @runner = Runner.new(@backend, agent_id:, parent_id:, stale_minutes:)
        @backend_name = @backend.name
      end

      # Claim a scope. `ALREADY YOURS` returns the result. A refusal raises.
      #
      # @param scope [String]
      # @param intent [String, nil]
      # @param enforce [Boolean] also freeze the matched files on macOS
      # @param allow_wide [Boolean] let `enforce` freeze more than {Freeze::LIMIT} files
      # @param dir [String, nil] act on the checkout that contains this directory
      # @param agent_id [String, nil]
      # @param parent_id [String, nil]
      # @param stale_minutes [Integer, nil]
      # @return [Manager::Result] :acquired or :already_mine
      # @raise [Refused] held, interrupted, or exactly the parent's scope
      # @raise [Scope::Invalid] when the scope is empty or outside the tree
      # @raise [Freeze::TooBroad] when `enforce` is wider than the limit and `allow_wide` is false
      def acquire(scope, intent = nil, enforce: false, allow_wide: false, **)
        runner.call(CLI::Commands::Acquire, scope:, intent:, enforce:, allow_wide:, **)
      end

      # @param scope [String]
      # @param dir [String, nil]
      # @param agent_id [String, nil]
      # @param parent_id [String, nil]
      # @param stale_minutes [Integer, nil]
      # @return [Manager::Result] :released, or :not_found when nothing is locked
      # @raise [Refused] when another agent holds it
      def release(scope, **)
        runner.call(CLI::Commands::Release, scope:, **)
      end

      # @param scope [String]
      # @param dir [String, nil]
      # @param agent_id [String, nil]
      # @param parent_id [String, nil]
      # @param stale_minutes [Integer, nil]
      # @return [Manager::Result] :free or :mine
      # @raise [Refused] when another agent holds an overlapping scope
      def check(scope, **)
        runner.call(CLI::Commands::Check, scope:, **)
      end

      # @param dir [String, nil]
      # @param agent_id [String, nil]
      # @param parent_id [String, nil]
      # @param stale_minutes [Integer, nil]
      # @return [Manager::Result] every lock in this facade's store
      def list(**)
        runner.call(CLI::Commands::List, **)
      end

      # @param dir [String, nil]
      # @param agent_id [String, nil]
      # @param parent_id [String, nil]
      # @param stale_minutes [Integer, nil]
      # @return [Manager::Result] locks held by this identity and its sub-agents
      def mine(**)
        runner.call(CLI::Commands::Mine, **)
      end

      # @param dir [String, nil]
      # @param agent_id [String, nil]
      # @param parent_id [String, nil]
      # @param stale_minutes [Integer, nil]
      # @return [Manager::Result] what was released
      def release_all(**)
        runner.call(CLI::Commands::ReleaseAll, **)
      end

      # `alock break`. The CLI's BREAKING lines are a warning on a command
      # that succeeded, so this returns the result instead of raising.
      #
      # @param scope [String]
      # @param dir [String, nil]
      # @param agent_id [String, nil]
      # @param parent_id [String, nil]
      # @param stale_minutes [Integer, nil]
      # @return [Manager::Result] :broken, or :not_found
      def break_lock(scope, **)
        runner.call(CLI::Commands::Break, scope:, **)
      end

      # @param scope [String]
      # @param text [String]
      # @param dir [String, nil]
      # @param agent_id [String, nil]
      # @param parent_id [String, nil]
      # @param stale_minutes [Integer, nil]
      # @return [Manager::Result] :noted
      # @raise [Refused] when this identity does not hold the lock
      def note(scope, text, **)
        runner.call(CLI::Commands::Note, scope:, text:, **)
      end

      # @param scope [String]
      # @param dir [String, nil]
      # @param agent_id [String, nil]
      # @param parent_id [String, nil]
      # @param stale_minutes [Integer, nil]
      # @return [Manager::Result] :resumed, or :not_found when there is nothing to resume
      # @raise [Refused] when the scope is held, or interrupted work is in the way
      def resume(scope, **)
        runner.call(CLI::Commands::Resume, scope:, **)
      end

      # Who a lock taken through this facade would name. Runs the `whoami`
      # command against the same identity, and returns that identity rather
      # than the printed lines.
      #
      # @param dir [String, nil]
      # @param agent_id [String, nil]
      # @param parent_id [String, nil]
      # @return [Identity]
      def whoami(**options)
        runner.call(CLI::Commands::Whoami, **options)
        runner.identity_for(options)
      end

      # @return [String] the directory of the bundled skill
      def skills_path
        runner.call(CLI::Commands::SkillsPath)
      end

      # `agent` is the command's `--for`. `into` wins when both are given,
      # which is what the command does.
      #
      # @param into [String, nil] skills directory. Nil uses the command's default.
      # @param agent [String, nil] `claude` installs into ~/.claude/skills
      # @param overwrite [Boolean] replace a copy that differs
      # @return [Skill::Result] :installed or :current
      # @raise [Refused] when the copy differs or the path is a symlink
      def skills_install(into: nil, agent: nil, overwrite: false)
        args = { overwrite: overwrite }
        args[:into] = into unless into.nil?
        args[:for] = agent unless agent.nil?
        runner.call(CLI::Commands::SkillsInstall, **args)
      end

      # @return [String] {VERSION}
      def version
        runner.call(CLI::Commands::Version)
      end

      private

      # @return [Backend]
      attr_reader :backend

      # @return [Runner]
      attr_reader :runner
    end

    class << self
      # A file-store facade, built on first use and reused after that.
      # Thread-safe. Independent of {.distributed} and of {Facade.new}.
      #
      # @return [Facade]
      def local
        memo(:local) { Facade.new(strategies: %w[file]) }
      end

      # A Redis facade, built on first use and reused after that.
      # Raises when Redis does not answer, and does not keep that failure:
      # a later call tries again. Thread-safe.
      #
      # @return [Facade]
      # @raise [RedisUnavailableError] when `REDIS_URL`, or {Facade::DEFAULT_REDIS_URL}, does not answer
      def distributed
        memo(:distributed) do
          Facade.new(strategies: %w[redis], redis_url: ENV.fetch("REDIS_URL", Facade::DEFAULT_REDIS_URL))
        end
      end

      # A new facade. Same default as the `alock` command: try Redis, and
      # use the file store when it does not answer.
      #
      # @param strategies [Array<String, Symbol>]
      # @param options [Hash] `redis_url`, `agent_id`, `parent_id`, `stale_minutes`
      # @return [Facade]
      def facade(strategies: Facade::DEFAULT_STRATEGIES, **)
        Facade.new(strategies: strategies, **)
      end

      # Drop the memoized {.local} and {.distributed} facades.
      #
      # @return [void]
      def reset_facades!
        FACADE_MUTEX.synchronize do
          @local_facade = nil
          @distributed_facade = nil
        end
      end

      private

      # Serializes the first build of {.local} and of {.distributed}.
      FACADE_MUTEX = Mutex.new
      private_constant :FACADE_MUTEX

      # @param name [Symbol]
      # @return [Facade]
      def memo(name)
        ivar = :"@#{name}_facade"
        existing = instance_variable_get(ivar)
        return existing if existing

        FACADE_MUTEX.synchronize do
          instance_variable_get(ivar) || instance_variable_set(ivar, yield)
        end
      end
    end
  end
end

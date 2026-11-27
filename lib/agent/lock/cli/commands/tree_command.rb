# frozen_string_literal: true

require_relative "base"
require_relative "../../facade/strategies"

module Agent
  module Lock
    module CLI
      module Commands
        # A command that works on the lock store of one checkout, and so
        # takes `--dir` to name which checkout that is, and
        # `--locking-strategy` and `--redis-url` to name which store.
        #
        # They are added in `inherited` rather than restated in every
        # subclass, so a new lock verb gets them by subclassing and cannot
        # forget one. Every verb takes the store flags, not `acquire` alone:
        # a lock taken on a named Redis is released on that same Redis.
        #
        # @abstract Subclass and implement `#call(**options)`.
        class TreeCommand < Base
          # @param subclass [Class<TreeCommand>]
          # @return [void]
          def self.inherited(subclass)
            super
            subclass.option :dir, type: :string, default: ".",
                                  desc: "Act on the checkout that contains this directory"
            subclass.option :locking_strategy, type: :string, aliases: ["-s"],
                                               desc: "redis or filesystem: where the locks live, instead of " \
                                                     "AGENT_LOCK_BACKEND or whichever answers first"
            subclass.option :redis_url, type: :string, aliases: ["-u"],
                                        desc: "The one Redis to use, with no fallback; implies " \
                                              "--locking-strategy redis (env: AGENT_LOCK_REDIS_URL)"
          end

          private

          # @param options [Hash] `:dir`, `:locking_strategy`, `:redis_url`
          # @return [Manager] bound to the tree that contains `--dir`, and to
          #   the store the flags name, when they name one
          # @raise [Dry::CLI::Error] for a strategy that is not one, or an empty URL
          # @raise [Store::Mismatch] for a Redis URL beside the file store
          def manager(options)
            tree = Tree.for(options[:dir] || ".")
            Manager.new(tree: tree, store: Store.for(tree, **store_options(options)))
          end

          # @param options [Hash]
          # @return [Hash] `backend:` and `redis_url:` for {Store.for}
          # @raise [Dry::CLI::Error]
          def store_options(options)
            url = options[:redis_url]&.strip
            # `-u "$UNSET"` must not quietly become "whichever answers first".
            raise Dry::CLI::Error, "--redis-url is empty" if url && url.empty?

            { backend: backend_named(options[:locking_strategy]), redis_url: url }
          end

          # @param strategy [String, nil] as typed
          # @return [String, nil] "redis" or "file"
          # @raise [Dry::CLI::Error] for anything else
          def backend_named(strategy)
            return if strategy.nil?

            Facade::Strategies.canonical(strategy.strip.downcase)
          rescue ArgumentError
            raise Dry::CLI::Error, "unknown --locking-strategy #{strategy.inspect}, expected redis or filesystem"
          end
        end
      end
    end
  end
end

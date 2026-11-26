# frozen_string_literal: true

require "redis"
require_relative "../error"
require_relative "../store"
require_relative "../store/file_system_store"
require_relative "../store/redis_store"
require_relative "strategies"

module Agent
  module Lock
    class Facade
      # The one store a facade uses for its whole life, chosen once.
      #
      # Strategies are tried in order: `file` is always usable, `redis` only
      # when its URL answers. A list that runs out without either raises
      # {RedisUnavailableError}.
      #
      # Frozen once built. The `::Redis` client it keeps is shared by every
      # thread calling the facade; redis-rb serializes its own commands, so
      # sharing it is safe.
      class Backend
        # Seconds to wait for Redis to answer the probe, so a dead URL costs
        # a fraction of a second instead of the client's default timeout.
        PROBE_TIMEOUT = 0.2

        # @return [String] "redis" or "file"
        attr_reader :name

        # @return [String] the Redis URL this backend was given
        attr_reader :redis_url

        # @param strategies [Array<String, Symbol>] see {Strategies.parse}
        # @param redis_url [String]
        # @raise [ArgumentError] when a strategy name is unknown, or the list is empty
        # @raise [RedisUnavailableError] when Redis was required and did not answer
        def initialize(strategies:, redis_url:)
          @redis_url = redis_url
          @name, @client = resolve(Strategies.parse(strategies))
          freeze
        end

        # Bound by the checkout's backend marker, exactly like `alock`: a
        # virgin tree is claimed for this backend, so the CLI follows the
        # facade there, and a tree already claimed for the other backend is
        # refused. Silently using another store would let a facade and an
        # `alock` in one checkout both "acquire" the same scope.
        #
        # @param tree [Tree]
        # @return [Store::FileSystemStore, Store::RedisStore] a store over `tree`
        # @raise [Store::Mismatch] when the tree's locks live in the other backend
        def store_for(tree)
          established = Store.claim(tree, name)
          unless established == name
            raise Store::Mismatch, "this tree's locks live in #{established}, but this facade uses #{name}; " \
                                   "build it with strategies: %w[#{established}]"
          end

          return Store::FileSystemStore.new(tree) if name == "file"

          Store::RedisStore.new(tree, client: @client, url: redis_url)
        end

        private

        # @param names [Array<String>]
        # @return [Array(String, ::Redis), Array(String, nil)]
        # @raise [RedisUnavailableError]
        def resolve(names)
          names.each do |name|
            return ["file", nil] if name == "file"

            client = connect
            return ["redis", client] if client
          end

          raise RedisUnavailableError, "Redis did not answer on #{redis_url}"
        end

        # Probes with a short-timeout client, then hands back one with the
        # gem's default timeouts: the probe's 0.2s would otherwise apply to
        # every lock operation on a slow, remote Redis.
        #
        # @return [::Redis, nil] a working client once Redis answered, or nil
        def connect
          probe = ::Redis.new(url: redis_url, timeout: PROBE_TIMEOUT, connect_timeout: PROBE_TIMEOUT)
          probe.ping
          ::Redis.new(url: redis_url)
        rescue ::Redis::BaseError, SystemCallError, SocketError
          nil
        ensure
          close_quietly(probe)
        end

        # @param client [::Redis, nil]
        # @return [void]
        def close_quietly(client)
          client&.close
        rescue StandardError
          nil
        end
      end
    end
  end
end

# frozen_string_literal: true

require "redis"
require_relative "../error"
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

        # @param tree [Tree]
        # @return [Store::FileSystemStore, Store::RedisStore] a store over `tree`
        def store_for(tree)
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

        # @return [::Redis, nil] a client that has answered once, or nil
        def connect
          client = ::Redis.new(url: redis_url, timeout: PROBE_TIMEOUT, connect_timeout: PROBE_TIMEOUT)
          client.ping
          client
        rescue ::Redis::BaseError, SystemCallError, SocketError
          close_quietly(client)
          nil
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

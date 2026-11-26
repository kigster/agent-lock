# frozen_string_literal: true

require "redis"
require_relative "../error"
require_relative "../store/file_system_store"
require_relative "../store/redis_store"

module Agent
  module Lock
    class Facade
      # The one backend this facade will use for its whole life.
      #
      # Strategies are tried in order. `file` and `filesystem` are the file
      # store. `redis` is kept when that URL answers. A list that never
      # reaches a usable store raises {RedisUnavailableError}.
      class Backend
        # Names that mean the file store.
        FILE_ALIASES = %w[file filesystem].freeze

        # @return [String] "redis" or "file"
        attr_reader :name

        # @return [String] the Redis URL this facade was given
        attr_reader :redis_url

        # @return [::Redis, nil] the connection `redis` is using. Nil for the file store.
        attr_reader :client

        # @param strategies [Array<String, Symbol>]
        # @param redis_url [String]
        # @raise [ArgumentError] when a strategy name is unknown, or the list is empty
        # @raise [RedisUnavailableError] when Redis was required and did not answer
        def initialize(strategies:, redis_url:)
          @redis_url = redis_url
          @name, @client = resolve(normalize(strategies))
        end

        # @param tree [Tree]
        # @return [Store::FileSystemStore, Store::RedisStore]
        def store_for(tree)
          return Store::FileSystemStore.new(tree) if name == "file"

          Store::RedisStore.new(tree, client: client, url: redis_url)
        end

        private

        # @param strategies [Array<String, Symbol>]
        # @return [Array<String>]
        def normalize(strategies)
          names = Array(strategies).map { |name| name.to_s.downcase }
          raise ArgumentError, "strategies must name at least one of redis, file" if names.empty?

          names.map { |name| known(name) }.uniq
        end

        # @param name [String]
        # @return [String]
        def known(name)
          return "file" if FILE_ALIASES.include?(name)
          return name if name == "redis"

          raise ArgumentError, "unknown strategy #{name.inspect}, expected redis or file"
        end

        # @param names [Array<String>]
        # @return [Array(String, ::Redis, nil)]
        def resolve(names)
          names.each do |name|
            return ["file", nil] if name == "file"

            client = connect
            return ["redis", client] if client
          end

          raise RedisUnavailableError, "Redis did not answer on #{redis_url}"
        end

        # @return [::Redis, nil]
        def connect
          client = ::Redis.new(url: redis_url, timeout: 0.2, connect_timeout: 0.2)
          client.info["redis_version"]
          client
        rescue Redis::BaseError, SystemCallError, SocketError
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

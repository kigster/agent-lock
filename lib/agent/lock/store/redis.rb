# frozen_string_literal: true

require_relative "../error"
require_relative "../record"

require "digest"

module Agent
  module Lock
    module Store
      # The same locks in a local Redis, for the machines that already run one.
      #
      # Redis buys two things the filesystem cannot: `SET NX` is atomic across
      # machines rather than only across processes on one, and a TTL expires an
      # abandoned lock without anybody having to reason about whether its holder
      # is still alive. It costs the thing that makes the file store pleasant,
      # which is that you can `cat` a lock, so the value stored is the same
      # markdown document either way.
      #
      # Opt in with AGENT_LOCK_BACKEND=redis. The `redis` gem is not a
      # dependency of this one; it is required only when this store is asked
      # for, so nobody pays for a backend they do not use.
      class Redis
        NAMESPACE = "agent-lock"

        attr_reader :tree

        def initialize(tree, client: nil)
          @tree = tree
          @client = client
        end

        # @return [String]
        def describe = "redis #{url} (#{namespace})"

        # SCAN rather than KEYS: this runs on whatever Redis the machine
        # already has, which may be somebody's shared development instance,
        # and KEYS blocks the server for the length of the scan.
        #
        # @return [Array<Record>]
        def all
          keys = client.scan_each(match: "#{namespace}:*").to_a.uniq.sort
          keys.filter_map { |key| parse(client.get(key), key) }
        end

        # @param scope [Scope]
        # @return [Record, nil]
        def find(scope) = parse(client.get(key_for(Record.id_for(tree, scope))), nil)

        # @param record [Record]
        # @return [Boolean]
        def create(record)
          args = { nx: true }
          args[:ex] = ttl_seconds if ttl_seconds.positive?
          !!client.set(key_for(record.id), record.to_markdown, **args)
        end

        # @param record [Record]
        # @return [void]
        def update(record) = client.set(key_for(record.id), record.to_markdown, keepttl: true)

        # @param record [Record]
        # @return [void]
        def delete(record) = client.del(key_for(record.id))

        # @param id [String]
        # @return [String]
        def key_for(id) = "#{namespace}:#{id}"

        private

        # Keyed by the tree, so one Redis serves every checkout on the machine
        # without their locks colliding.
        def namespace = "#{NAMESPACE}:#{Digest::SHA256.hexdigest(tree.root)[0, 12]}"

        def ttl_seconds = Integer(ENV.fetch("AGENT_LOCK_TTL_SECONDS", 0))

        def url = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")

        def parse(text, key)
          return nil if text.nil?

          record = Record.parse(text)
          record && key ? record.with(id: key.split(":").last) : record
        end

        def client
          @client ||= begin
            require "redis"
            ::Redis.new(url: url)
          rescue LoadError
            raise Error, "AGENT_LOCK_BACKEND=redis needs the redis gem: gem install redis"
          end
        end
      end
    end
  end
end

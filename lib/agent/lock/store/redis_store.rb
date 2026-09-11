# frozen_string_literal: true

require_relative "../error"
require_relative "../record"

require "redis"
require "digest"
require "securerandom"

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
      # Picked with AGENT_LOCK_BACKEND=redis, or by default when one answers on
      # REDIS_URL. See Store's moduledoc for how that default is decided.
      class RedisStore
        NAMESPACE = "agent-lock"

        # How long the store mutex outlives a holder that died holding it. A
        # claim's critical section is a SCAN and one SET, so ten seconds is
        # somebody gone, not somebody busy.
        MUTEX_LEASE_MS = 10_000

        # Seconds to wait for the mutex. Longer than the lease, so that a
        # crashed holder is waited out rather than reported.
        MUTEX_TIMEOUT = 15

        LEASE_LOST = "the lock store's mutex lease (#{MUTEX_LEASE_MS}ms) ran out before the claim finished, " \
                     "so another process may have claimed an overlapping scope: check the listing".freeze

        RELEASE = <<~LUA
          if redis.call("GET", KEYS[1]) == ARGV[1] then
            return redis.call("DEL", KEYS[1])
          end
          return 0
        LUA

        attr_reader :tree, :client

        def initialize(tree, client: nil)
          @tree = tree

          if client.nil?
            client, error = self.class.create_client
            raise(error) if client.nil? && error

            @client = client if client
          else
            @client = client
          end

          raise "no functional Redis client could be created for #{self.class.url}" unless @client
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

        # Runs the block with every other process in this store shut out, so a
        # scan for conflicts and the write it justifies cannot be interleaved.
        # SET NX alone settles a race for one scope, but `lib/**` and
        # `lib/a1.rb` are two keys, and two agents that both scanned an empty
        # namespace before either wrote both won.
        #
        # The mutex is a key set with NX to a token only this call knows, and
        # leased rather than held: a holder that dies mid-claim cannot release
        # it, so the lease does, within MUTEX_LEASE_MS. The wait for it is
        # bounded, and longer than the lease, so a crashed holder costs the
        # next agent a pause and never an error.
        #
        # Not re-entrant. A nested call waits on its own mutex until the lease
        # frees it, and the outer call then finds it gone and raises.
        #
        # @yield the critical section
        # @return [Object] whatever the block returns
        # @raise [Error] when the mutex stayed held for longer than the timeout,
        #   or the block outlived its lease and ran unprotected for a while
        def synchronize
          token = SecureRandom.hex(16)
          wait_for(token)
          begin
            outcome = yield
          ensure
            released = release(token)
          end
          raise Error, LEASE_LOST unless released

          outcome
        end

        # Outside the namespace on purpose. `all` scans `<namespace>:*`, and a
        # mutex inside it would be read back as a lock on every scan.
        #
        # @return [String]
        def mutex_key = "#{NAMESPACE}-mutex:#{digest}"

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

        # Keyed by the tree, so one Redis instance serves every checkout on the
        # machine without their locks colliding.
        def namespace = "#{NAMESPACE}:#{digest}"

        # @return [String]
        def url = self.class.url

        def digest = ::Digest::SHA256.hexdigest(tree.root)[0, 12]

        # SET NX PX until it takes, backing off with jitter so that processes
        # which all lost the same round do not all come back for the next one
        # at the same instant.
        #
        # @param token [String] what the key is set to, so release can tell
        #   this holder's mutex from the next one's
        # @return [void]
        # @raise [Error] once the timeout has passed
        def wait_for(token)
          timeout = mutex_timeout
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          delay = 0.005
          until client.set(mutex_key, token, nx: true, px: MUTEX_LEASE_MS)
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              raise Error, format("timed out after %<timeout>gs waiting for %<key>s in %<url>s, " \
                                  "which another process claiming a lock is holding", timeout:, key: mutex_key, url:)
            end

            sleep(delay * rand(0.5..1.0))
            delay = [delay * 2, 0.1].min
          end
        end

        # Compare and delete in one step. A plain DEL after a GET could land
        # after the lease ran out and somebody else took the mutex, and would
        # then let a third process in beside the second.
        #
        # @param token [String]
        # @return [Boolean] false when the mutex was no longer this holder's
        def release(token) = client.eval(RELEASE, keys: [mutex_key], argv: [token]) == 1

        # @return [Float] seconds to wait for the mutex before giving up
        # @raise [Error] when AGENT_LOCK_MUTEX_TIMEOUT is not a finite,
        #   non-negative number: `Float` accepts "Infinity" and "NaN", and
        #   either makes the deadline in `wait_for` unreachable, hanging the
        #   poll loop forever instead of timing out.
        def mutex_timeout
          timeout = Float(ENV.fetch("AGENT_LOCK_MUTEX_TIMEOUT", MUTEX_TIMEOUT))
          unless timeout.finite? && timeout >= 0
            raise Error, "AGENT_LOCK_MUTEX_TIMEOUT must be a finite, non-negative number, got #{timeout}"
          end

          timeout
        end

        def ttl_seconds = Integer(ENV.fetch("AGENT_LOCK_TTL_SECONDS", 0))

        def parse(text, key)
          return nil if text.nil?

          record = Record.parse(text)
          record && key ? record.with(id: key.split(":").last) : record
        end

        class << self
          def url = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")

          # @return Array[RedisClient,NilClass,Exception] the client if it could be created,
          # or the error that prevented it
          def create_client
            @client ||= ::Redis.new(url: url).tap do |client|
              _version = client.info["redis_version"]
            end
            [@client, nil]
          rescue Redis::CannotConnectError, Redis::BaseError, Errno::ECONNREFUSED, SocketError => e
            [nil, e]
          end
        end
      end
    end
  end
end

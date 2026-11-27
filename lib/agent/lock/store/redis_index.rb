# frozen_string_literal: true

require "socket"
require_relative "redis_store"
require_relative "../record"

module Agent
  module Lock
    module Store
      # Every lock in one Redis, across repositories. The file store has no
      # equivalent: its records live inside one checkout's `.git` and cannot
      # be listed from anywhere else.
      #
      # Keys are the ones {RedisStore} writes, `[alock-<version>-<slug>]-<sha256>:<id>`.
      # The mutex beside them is not a lock and is skipped. Anything still
      # under the old `agent-lock:` prefix is skipped too.
      class RedisIndex
        # A lock key. The slug is everything after `alock-v<major>-`
        # up to the closing bracket, which for GitHub is `owner/name`.
        LOCK_KEY = /\A\[(?<label>alock-v\d+-(?<slug>[^\]]+))\]-(?<digest>[0-9a-f]{64}):(?<id>.+)\z/

        # One row of `show repos`.
        #
        # @!attribute [r] namespace
        #   @return [String] `alock-v4-kigster/laser-cutter`, brackets aside
        # @!attribute [r] count
        #   @return [Integer] locks under that label, every branch included
        # @!attribute [r] bytes
        #   @return [Integer, nil] their `MEMORY USAGE` summed, nil when Redis
        #     cannot say
        Repo = Data.define(:namespace, :count, :bytes)

        # One lock, still carrying the record {RedisStore} wrote.
        #
        # @!attribute [r] record
        #   @return [Record]
        # @!attribute [r] namespace
        #   @return [String] the same label as {Repo#namespace}
        Lock = Data.define(:record, :namespace)

        # @param client [::Redis]
        def initialize(client)
          @client = client
        end

        # @param url [String, nil] nil searches the way {RedisStore.open} does
        # @return [RedisIndex]
        # @raise [Store::Unreachable]
        def self.open(url = nil) = new(RedisStore.open(url))

        # `github.com/kigster/laser-cutter` and `kigster/laser-cutter` are the
        # same repository. Anything that is not `owner/name` is refused rather
        # than matched against a prefix of some other slug.
        #
        # @param text [String]
        # @return [String]
        # @raise [Error]
        def self.normalize_slug(text)
          slug = text.to_s.strip.sub(%r{\Agithub\.com/}i, "").delete_suffix(".git").delete_suffix("/")
          return slug if slug.match?(%r{\A[^/]+/[^/]+\z})

          raise Error, "pass the repository as owner/name, for example kigster/laser-cutter"
        end

        # @param bytes [Integer, nil]
        # @return [String]
        def self.format_bytes(bytes)
          return "n/a" if bytes.nil?
          return "#{bytes} B" if bytes < 1024

          value, unit = bytes < (1024 * 1024) ? [bytes / 1024.0, "KB"] : [bytes / (1024.0 * 1024), "MB"]
          format("%<value>.1f %<unit>s", value:, unit:)
        end

        # @return [Array<Repo>] every label, fewest locks last
        def repos
          grouped.map { |label, entries| Repo.new(label, entries.size, bytes_of(entries)) }
                 .sort_by { |repo| [-repo.count, repo.namespace] }
        end

        # @param slug [String] `owner/name`, or a GitHub URL path
        # @return [Array<Lock>]
        # @raise [Error] when `slug` is not `owner/name`
        def locks(slug)
          wanted = self.class.normalize_slug(slug)
          pattern = /\Aalock-v\d+-#{Regexp.escape(wanted)}\z/
          grouped.select { |label, _entries| label.match?(pattern) }
                 .flat_map { |label, entries| entries.map { |entry| Lock.new(entry[:record], label) } }
                 .sort_by { |lock| [lock.record.scope, lock.record.created_at.to_s] }
        end

        # Whether the holder can be checked from this machine, and the answer.
        #
        # A pid on another host cannot be asked. Reporting it alive is how a
        # dead process on a build box used to look occupied forever.
        #
        # @param record [Record]
        # @return [String] "yes", "no", or "unknown"
        def self.alive(record)
          here = record.host.nil? || record.host == Socket.gethostname
          return "unknown" unless here && record.pid

          ProcessInfo.alive?(record.pid, started: record.started) ? "yes" : "no"
        end

        private

        attr_reader :client

        # @return [Hash{String => Array<Hash>}]
        def grouped
          @grouped ||= each_lock.group_by { |entry| entry[:label] }
        end

        # @return [Array<Hash>]
        def each_lock
          client.scan_each(match: "[[]alock-*").to_a.uniq.filter_map { |key| read(key) }
        end

        # @param key [String]
        # @return [Hash, nil] nil for the mutex and for a value that is not a lock
        def read(key)
          found = LOCK_KEY.match(key)
          return nil unless found

          record = Record.parse(client.get(key))
          return nil unless record

          { label: found[:label], key: key, record: record.with(id: found[:id]) }
        end

        # @param entries [Array<Hash>]
        # @return [Integer, nil] nil when Redis has no MEMORY USAGE
        def bytes_of(entries)
          entries.sum { |entry| memory(entry[:key]) }
        rescue Redis::CommandError
          nil
        end

        # @param key [String]
        # @return [Integer]
        # @raise [Redis::CommandError] when this Redis has no MEMORY USAGE
        def memory(key)
          client.call("MEMORY", "USAGE", key).to_i
        end
      end
    end
  end
end

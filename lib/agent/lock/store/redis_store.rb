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
      # REDIS_URL, or failing that on the local default. See Store's moduledoc
      # for how that default is decided.
      class RedisStore
        # Tried after REDIS_URL, or alone when it is unset.
        LOCAL_URL = "redis://127.0.0.1:6379/0"

        # How long the store mutex outlives a holder that died holding it. A
        # claim's critical section is a SCAN and one SET, so ten seconds is
        # somebody gone, not somebody busy.
        MUTEX_LEASE_MS = 10_000

        # Seconds to wait for the mutex. Longer than the lease, so that a
        # crashed holder is waited out rather than reported.
        MUTEX_TIMEOUT = 15

        # The error raised when the mutex expired under a running claim.
        LEASE_LOST = "the lock store's mutex lease (#{MUTEX_LEASE_MS}ms) ran out before the claim finished, " \
                     "so another process may have claimed an overlapping scope: check the listing".freeze

        # Compare-and-delete: release the mutex only while it still holds our
        # token, so a process whose lease ran out cannot free somebody else's.
        RELEASE = <<~LUA
          if redis.call("GET", KEYS[1]) == ARGV[1] then
            return redis.call("DEL", KEYS[1])
          end
          return 0
        LUA

        attr_reader :tree, :client

        # @param tree [Tree] the checkout whose repository names the namespace
        # @param client [::Redis, nil] nil connects through {.create_client}.
        #   A facade passes its own client so two facades can use two servers.
        # @param url [String, nil] the URL `client` speaks. Nil uses {.url}.
        # @raise [RuntimeError] when no client can be created
        def initialize(tree, client: nil, url: nil)
          @tree = tree
          @url = url

          if client.nil?
            client, error = self.class.create_client
            raise(error) if client.nil? && error

            @client = client if client
          else
            @client = client
          end

          raise "no functional Redis client could be created for #{self.url}" unless @client
        end

        # @return [String]
        def describe = "redis #{url} (#{namespace})"

        # SCAN rather than KEYS: this runs on whatever Redis the machine
        # already has, which may be somebody's shared development instance,
        # and KEYS blocks the server for the length of the scan.
        #
        # @return [Array<Record>]
        def all
          keys = client.scan_each(match: scan_match).to_a.uniq.sort
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

        # One per repository, shared by every branch. A checkout that switched
        # branches still writes the lock it took on the old one, and that write
        # has to shut out whoever is on the branch it left. `all` scans
        # `<label>-<hex>*`, so the mutex sits beside that pattern rather than
        # inside it, or every scan would read the mutex back as a lock.
        #
        # @return [String]
        def mutex_key = "#{label}-mutex"

        # @param scope [Scope]
        # @return [Record, nil]
        def find(scope) = parse(client.get(key_for(Record.id_for(tree, scope))), nil)

        # Named to match the Store interface FileSystemStore shares: an action
        # with a boolean outcome, not a pure predicate.
        #
        # @param record [Record]
        # @return [Boolean]
        # rubocop:disable-next Naming/PredicateMethod
        def create(record)
          args = { nx: true }
          args[:ex] = ttl_seconds if ttl_seconds.positive?
          !!client.set(key_for(record.id, record.lock_key), record.to_markdown, **args)
        end

        # @param record [Record]
        # @return [void]
        def update(record) = client.set(key_for(record.id, record.lock_key), record.to_markdown, keepttl: true)

        # @param record [Record]
        # @return [void]
        def delete(record) = client.del(key_for(record.id, record.lock_key))

        # The branch the id was taken on decides the key, not the branch this
        # checkout is on now. A session that switched branches after claiming
        # still has to release the record it wrote, and that record's lock key
        # names the branch it was taken on.
        #
        # @param id [String]
        # @param lock_key [String] {Tree#lock_key} for the checkout that owns the id
        # @return [String]
        def key_for(id, lock_key = tree.lock_key) = "#{namespace_for(lock_key)}:#{id}"

        # Where this checkout writes. Every branch of the repository has its
        # own, under one readable label, and {#all} reads them all.
        #
        # @return [String] `[alock-<major>.<minor>-<owner>/<repo>]-<sha256>`
        def namespace = namespace_for(tree.lock_key)

        private

        # `[alock-4.0-kigster/laser-cutter]`. The brackets are literal, so a
        # person reading `KEYS` can see the gem and the repository. Major and
        # minor only: a patch keeps the keys it wrote, a minor starts a new
        # set. GitHub is `owner/repo`; any other host keeps its host, so two
        # forges with the same owner and name do not share a label.
        #
        # @return [String]
        def label = "[alock-#{self.class.version_tag}-#{tree.redis_slug}]"

        # The label, then the SHA-256 of the lock key. On a branch the lock
        # key is `repository@branch`, which every worktree and every machine
        # on that branch computes the same way, so they share the key. The
        # checkout's path stays out of it: hashing the path is what used to
        # keep two machines from seeing each other. A detached HEAD has no
        # branch, and its lock key is `host:worktree-path`, so that worktree
        # hashes alone.
        #
        # @param lock_key [String]
        # @return [String]
        def namespace_for(lock_key) = "#{label}-#{::Digest::SHA256.hexdigest(lock_key)}"

        # `all` has to see every branch, so it matches the label and any hex
        # digest rather than this checkout's own. Redis SCAN treats `[]` as a
        # character class. The label starts and ends with brackets, and an
        # unescaped pattern matches one character instead of the key, which
        # lists nothing and lets every claim through. `[[]` is one literal `[`.
        # The mutex ends in `-mutex`, and `m` is outside `[0-9a-f]`, so the
        # scan does not return it.
        #
        # @return [String]
        def scan_match = "#{label.sub("[", "[[]")}-[0-9a-f]*"

        # @return [String] the URL this store was given, or the one
        #   {.create_client} settled on when it was not
        def url = @url || self.class.url

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
        # rubocop:disable-next Naming/PredicateMethod
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

        # @return [Integer] AGENT_LOCK_TTL_SECONDS; 0 means no expiry
        def ttl_seconds = Integer(ENV.fetch("AGENT_LOCK_TTL_SECONDS", 0))

        # @param text [String, nil] the stored lock document
        # @param key [String, nil] its Redis key, whose last segment is the id
        # @return [Record, nil]
        def parse(text, key)
          return nil if text.nil?

          record = Record.parse(text)
          record && key ? record.with(id: key.split(":").last) : record
        end

        class << self
          # A store on one named Redis, and no other: no `REDIS_URL`, no
          # local default, no memoized client.
          #
          # @param tree [Tree]
          # @param url [String] a Redis URL
          # @return [RedisStore]
          # @raise [Store::Unreachable] when nothing answers on `url`
          def at(tree, url)
            client, error = connect(url)
            raise Store::Unreachable, "cannot use Redis at #{safe(url)}: #{reason(error)}" unless client

            new(tree, client: client, url: url)
          end

          # A store on the first Redis the search finds.
          #
          # @param tree [Tree]
          # @return [RedisStore]
          # @raise [Store::Unreachable] when none of {.candidate_urls} answers
          def found(tree)
            client, error = create_client
            return new(tree, client: client) if client

            raise Store::Unreachable, "no Redis answered on #{candidate_urls.map { |u| safe(u) }.join(" or ")}: " \
                                      "#{reason(error)}"
          end

          # A client for a command that reads every repository in one Redis,
          # rather than the locks of one checkout. An explicit URL is tried
          # alone. Without one, {.create_client} searches as usual.
          #
          # @param url [String, nil]
          # @return [::Redis]
          # @raise [Store::Unreachable] when it does not answer
          def open(url = nil)
            client, error = url ? connect(url) : create_client
            return client if client

            where = url ? safe(url) : candidate_urls.map { |candidate| safe(candidate) }.join(" or ")
            raise Store::Unreachable, "cannot use Redis at #{where}: #{reason(error)}"
          end

          # A URL fit to print: an error lands in transcripts and logs, and
          # a Redis URL may carry a password.
          #
          # @param url [String]
          # @return [String] `url` with any userinfo replaced by `***`
          def safe(url) = url.to_s.gsub(%r{(?<=://)[^/@\s]*@}, "***@")

          # @return [String] `4.0` from `4.0.3`. A patch stays in the namespace
          #   it wrote; a new minor starts another one.
          def version_tag
            major, minor, = ::Agent::Lock::VERSION.split(".")
            "#{major}.#{minor}"
          end

          # redis-rb words its own errors without the password; anything
          # else (a URL that does not parse) may quote the URL back.
          #
          # @param error [Exception]
          # @return [String]
          def reason(error) = error.is_a?(::Redis::BaseError) ? error.message : error.class.name

          # The URL of the Redis actually in use, once one has answered, or
          # the first one that will be tried before then.
          #
          # @return [String]
          def url = @url || candidate_urls.first

          # Where to look, in order: `REDIS_URL` when set, then the local
          # default. A `REDIS_URL` that nobody answers on is not the end of
          # the search, because the usual reason it is set is a shared
          # instance that is sometimes down, and a local one is still better
          # than falling all the way back to the filesystem.
          #
          # @return [Array<String>]
          def candidate_urls
            configured = ENV["REDIS_URL"].to_s.strip
            [configured.empty? ? nil : configured, LOCAL_URL].compact.uniq
          end

          # Tries each candidate URL in turn and keeps the first that answers.
          #
          # @return [Array(Redis, nil), Array(nil, Exception)] the client and nil,
          #   or nil and the error from the last URL tried
          def create_client
            return [@client, nil] if @client

            error = nil
            candidate_urls.each do |candidate|
              client, error = connect(candidate)
              next unless client

              @url = candidate
              @client = client
              return [@client, nil]
            end
            [nil, error]
          end

          # Drops the memoized client, so the next `create_client` probes again.
          #
          # @return [void]
          def reset!
            @client = nil
            @url = nil
          end

          private

          # @param candidate [String] a Redis URL
          # @return [Array(Redis, nil), Array(nil, Exception)] the client, or the error
          def connect(candidate)
            client = ::Redis.new(url: candidate)
            client.info["redis_version"]
            [client, nil]
          rescue Redis::CannotConnectError, Redis::BaseError, SystemCallError, SocketError, ArgumentError,
                 URI::InvalidURIError => e
            [nil, e]
          end
        end
      end
    end
  end
end

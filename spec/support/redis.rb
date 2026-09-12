# frozen_string_literal: true

# Whether a real Redis is actually there, for specs that skip rather than
# fail when the machine running them does not have one.
module RedisHelpers
  # Fixed, not read from REDIS_URL: an ambient value picked up from whatever
  # unrelated project's shell config happens to be loaded is exactly the kind
  # of thing that should never decide what a flush touches. Database 15 by
  # convention, so this is never whatever database a developer's own Redis
  # work, or this suite's own default-backend probing, lives in.
  TEST_REDIS_URL = "redis://127.0.0.1:6379/15"

  # @param url [String]
  # @return [Boolean]
  def redis_reachable?(url)
    ::Redis.new(url: url, timeout: 0.2).ping == "PONG"
  rescue StandardError
    false
  end

  # Every example that goes through `Store.for` picks a fresh tree, so a
  # per-tree sweep never collides with another example. But nothing on disk
  # marks a tree done with, unlike the file store's tmpdir, so records for a
  # tree nobody will ever ask about again would sit in Redis forever. A blunt
  # flush after every example is simpler than tracking which trees to sweep.
  #
  # Gated on AGENT_LOCK_BACKEND, and only ever against TEST_REDIS_URL, so a
  # file-backend run never opens a Redis connection at all, and a redis-backend
  # run can never be pointed at a real database by anything in the shell.
  #
  # @return [void]
  def flush_test_redis!
    return unless ENV["AGENT_LOCK_BACKEND"] == "redis"
    return unless redis_reachable?(TEST_REDIS_URL)

    ::Redis.new(url: TEST_REDIS_URL).flushdb
  end
end

RSpec.configure do |config|
  config.include RedisHelpers
  config.after { flush_test_redis! }
end

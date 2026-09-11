# frozen_string_literal: true

# Whether a real Redis is actually there, for specs that skip rather than
# fail when the machine running them does not have one.
module RedisHelpers
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
  # flush after every example is simpler than tracking which trees to sweep,
  # and safe because REDIS_URL for the suite defaults to database 15, never
  # whatever database a developer's own Redis work lives in.
  #
  # @return [void]
  def flush_test_redis!
    url = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/15")
    return unless redis_reachable?(url)

    ::Redis.new(url: url).flushdb
  end
end

RSpec.configure do |config|
  config.include RedisHelpers
  config.after { flush_test_redis! }
end

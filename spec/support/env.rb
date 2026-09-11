# frozen_string_literal: true

# Environment variables, scoped to a block and restored after, for specs that
# need to see a real ENV value rather than a stub of one.
module EnvHelpers
  # @param pairs [Hash{String => String}]
  # @yield with the environment set
  def with_env(pairs)
    previous = ENV.slice(*pairs.keys)
    ENV.update(pairs)
    yield
  ensure
    pairs.each_key { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end
end

RSpec.configure do |config|
  config.include EnvHelpers
end

# frozen_string_literal: true

module Agent
  module Lock
    class Facade
      # Turns the `strategies:` a caller passed into the backend names a
      # {Backend} tries, in order.
      module Strategies
        # Names that mean the file store.
        FILE_ALIASES = %w[file filesystem].freeze

        module_function

        # @param strategies [Array<String, Symbol>] e.g. `%w[redis filesystem]`
        # @return [Array<String>] "redis" and "file", in the order given, without repeats
        # @raise [ArgumentError] when the list is empty or names an unknown backend
        def parse(strategies)
          names = Array(strategies).map { |name| canonical(name.to_s.strip.downcase) }.uniq
          raise ArgumentError, "strategies must name at least one of redis, file" if names.empty?

          names
        end

        # @param name [String]
        # @return [String] "redis" or "file"
        # @raise [ArgumentError] for anything else
        def canonical(name)
          return "file" if FILE_ALIASES.include?(name)
          return name if name == "redis"

          raise ArgumentError, "unknown strategy #{name.inspect}, expected redis or file"
        end
      end
    end
  end
end

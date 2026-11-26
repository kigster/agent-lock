# frozen_string_literal: true

module Agent
  module Lock
    # The base of everything this gem raises. In a file of its own so that any
    # part of the library can require it without reaching for the entry point,
    # which would require the part doing the asking.
    class Error < StandardError; end

    # A lock operation the CLI would have explained on stderr and refused.
    #
    # The message is that text. `result` is the {Manager::Result} or
    # {Skill::Result} behind it, so the records are available without parsing
    # the message.
    #
    # @example
    #   begin
    #     facade.acquire("lib/**")
    #   rescue Agent::Lock::Refused => e
    #     e.result.record.agent_id
    #   end
    class Refused < Error
      # @return [Manager::Result, Skill::Result, nil] the operation that was refused
      attr_reader :result

      # @param message [String] the text the CLI would have written to stderr
      # @param result [Manager::Result, Skill::Result, nil]
      def initialize(message, result: nil)
        super(message)
        @result = result
      end
    end

    # Redis was required and did not answer.
    #
    # A {RuntimeError}, so a caller can rescue the connection failure apart
    # from a {Refused} lock. Raised while a {Facade} is constructed, before
    # any lock is taken, when every strategy has been tried and none was the
    # file store.
    #
    # @example
    #   Agent::Lock::Facade.new(strategies: %w[redis], redis_url: "redis://127.0.0.1:1")
    class RedisUnavailableError < RuntimeError; end
  end
end

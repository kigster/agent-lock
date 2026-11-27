# frozen_string_literal: true

module Agent
  module Lock
    class Facade
      # `locker.async`: every lock method of a {Facade}, run on
      # concurrent-ruby's I/O pool and answered with a
      # `Concurrent::Promises::Future`.
      #
      # A proxy of our own rather than `Concurrent::Async`, whose
      # `method_missing` forwards positional arguments only: there,
      # `async.acquire("lib/**", agent_id: "other")` folded the keywords
      # into `intent`, and the lock was taken, reported as acquired, and
      # signed by the facade's default holder in whatever checkout the
      # process happened to be in. Here keywords and blocks reach the facade
      # exactly as they would on a direct call.
      #
      # A future nobody waits on can be dropped when the process exits with
      # the pool still busy. Call `value!` or `wait` on every future whose
      # outcome matters, a `release` most of all.
      class Async
        # The facade methods offered asynchronously: the ones that touch a
        # store. `version`, `skills_path` and the like answer at once.
        METHODS = %i[acquire release check list mine release_all break_lock note resume whoami].freeze

        # concurrent-ruby is not a dependency of this gem. Only an `async:`
        # facade needs it, so only an `async:` facade asks for it.
        #
        # @return [void]
        # @raise [LoadError] naming the gem to add, when it is not installed
        def self.load!
          require "concurrent"
        rescue LoadError => e
          raise LoadError, "Agent::Lock::Facade.new(async: true) needs the concurrent-ruby gem: " \
                           "add `gem \"concurrent-ruby\"` to your Gemfile (#{e.message})"
        end

        # @param facade [Facade] the locker every call is made on
        def initialize(facade)
          @facade = facade
          freeze
        end

        METHODS.each do |name|
          # @return [Concurrent::Promises::Future] fulfilled with what the
          #   facade method returns, or rejected with what it raised
          define_method(name) do |*args, **kwargs, &block|
            facade = @facade
            Concurrent::Promises.future_on(:io) { facade.public_send(name, *args, **kwargs, &block) }
          end
        end
      end
    end
  end
end

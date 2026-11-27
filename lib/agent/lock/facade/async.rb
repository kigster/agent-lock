# frozen_string_literal: true

module Agent
  module Lock
    class Facade
      # `locker.async`: every lock method of a {Facade}, run off the calling
      # thread and answered with a `Concurrent::Promises::Future`.
      #
      # A proxy of our own rather than `Concurrent::Async`, whose
      # `method_missing` forwards positional arguments only: there,
      # `async.acquire("lib/**", agent_id: "other")` folded the keywords
      # into `intent`, and the lock was taken, reported as acquired, and
      # signed by the facade's default holder in whatever checkout the
      # process happened to be in. Here keywords and blocks reach the facade
      # exactly as they would on a direct call.
      #
      # One facade's calls run one at a time, in the order they were made.
      # Handing each call to the I/O pool on its own ran them in parallel:
      # an `async.release` could overtake the `async.acquire` issued before
      # it, and fifty `async.note` calls on one scope, each reading the
      # record, adding its note and writing it back, kept two notes while
      # every future reported `:noted`.
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
          @queue = Concurrent::SerializedExecutionDelegator.new(Concurrent.global_io_executor)
          @running = :"agent_lock_async_#{object_id}"
          freeze
        end

        METHODS.each do |name|
          # @return [Concurrent::Promises::Future] fulfilled with what the
          #   facade method returns, or rejected with what it raised
          define_method(name) do |*args, **kwargs, &block|
            Concurrent::Promises.future_on(executor) do
              queued { @facade.public_send(name, *args, **kwargs, &block) }
            end
          end
        end

        private

        # A call made from inside one of this proxy's own calls (the block
        # of an `async.acquire`) runs where it stands. Queued, it would wait
        # behind the very call that is waiting for it.
        #
        # @return [Symbol, Concurrent::SerializedExecutionDelegator]
        def executor = Thread.current[@running] ? :immediate : @queue

        # @yield the facade call
        # @return [Object] whatever the call returns
        def queued
          nested = Thread.current[@running]
          Thread.current[@running] = true
          yield
        ensure
          Thread.current[@running] = nested
        end
      end
    end
  end
end

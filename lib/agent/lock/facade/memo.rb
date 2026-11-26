# frozen_string_literal: true

module Agent
  module Lock
    class Facade
      # One value, built on first use by exactly one thread and reused after.
      #
      # A build that raises is not kept, so the next call tries again: a
      # Redis that was down for {Agent::Lock.distributed} is retried, not
      # remembered as down. Each memo has its own mutex, so a slow build of
      # one never blocks another.
      class Memo
        # @yieldreturn [Object] the value, built under the memo's mutex
        def initialize(&build)
          @build = build
          @mutex = Mutex.new
          @value = nil
        end

        # @return [Object] the value, building it if this is the first call
        def value = @mutex.synchronize { @value ||= @build.call }

        # Forget the value, so the next {#value} builds a new one.
        #
        # @return [void]
        def reset = @mutex.synchronize { @value = nil }
      end
    end
  end
end

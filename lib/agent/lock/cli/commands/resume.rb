# frozen_string_literal: true

require_relative "base"

module Agent
  module Lock
    module CLI
      module Commands
        # Pick up work a reboot or a crash interrupted.
        #
        # A lock whose holder died is orphaned rather than deleted when it has
        # notes in it. This takes it back, prints what the last session wrote,
        # and makes it a live claim again under the current identity.
        class Resume < Base
          desc "Take back a lock a crash or a reboot interrupted"

          argument :scope, required: true, desc: "The path or glob to pick up"

          def call(scope:, **options)
            result = manager(options[:dir]).resume(scope)

            if result.status == :not_found
              say("NOTHING TO RESUME #{scope}")
            else
              say("RESUMED #{result.record.scope}  (holder: #{result.record.agent_id})")
              say("")
              say(result.record.intent)
            end

            finish(result)
          end
        end
      end
    end
  end
end

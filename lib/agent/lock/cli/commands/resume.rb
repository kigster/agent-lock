# frozen_string_literal: true

require_relative "tree_command"

module Agent
  module Lock
    module CLI
      module Commands
        # Pick up work a reboot or a crash interrupted.
        #
        # A lock whose holder died is orphaned rather than deleted when it has
        # notes in it. This takes it back, prints what the last session wrote,
        # and makes it a live claim again under the current identity.
        class Resume < TreeCommand
          desc "Take back work a crash or reboot interrupted, notes and all"

          argument :scope, required: true, desc: "The scope of the interrupted lock"

          example ["'db/**'"]

          # @param scope [String]
          # @param options [Hash] `:dir`, `:locking_strategy`, `:redis_url`
          # @return [Manager::Result] :resumed, :not_found, :held or :interrupted
          def call(scope:, **options)
            manager = manager(options)
            result = manager.resume(scope)
            report(result, scope, manager.stale_minutes)
            finish(result)
          end

          private

          # @param result [Manager::Result]
          # @param scope [String] as typed
          # @param stale_minutes [Integer]
          # @return [void]
          def report(result, scope, stale_minutes)
            case result.status
            when :not_found then say("NOTHING TO RESUME #{scope}")
            when :held
              # Somebody claimed an overlapping scope while the work sat
              # orphaned; their claim is live and this one is not.
              warn_("REFUSED, somebody claimed it while it was interrupted; the notes are still there")
              report_held(result.records, stale_minutes: stale_minutes)
            when :interrupted
              warn_("REFUSED, #{result.record&.agent_id || "another session"} left interrupted work " \
                    "on #{scope} on this branch; resume or break that first")
            else
              say("RESUMED #{result.record.scope}  (holder: #{result.record.agent_id})")
              say("")
              say(result.record.intent)
            end
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require_relative "base"

module Agent
  module Lock
    module CLI
      module Commands
        # Take a lock away from whoever holds it.
        #
        # Deliberately blunt and deliberately loud: an expired lock is reaped
        # on its own, so reaching for this means overruling a holder that still
        # looks alive. Whoever runs it owns the consequence.
        class Break < Base
          desc "Steal a lock; announce it first"

          argument :scope, required: true, desc: "The path or glob to take"

          def call(scope:, **options)
            result = manager(options[:dir]).break_lock(scope)

            if result.status == :not_found
              say("NOT LOCKED #{scope}")
            else
              warn_("BREAKING #{result.record.scope}, held by #{result.record.agent_id}")
              warn_("  intent: #{result.record.intent}") unless result.record.intent.empty?
              say("Broken. You are responsible for having announced this first.")
            end

            finish(result)
          end
        end
      end
    end
  end
end

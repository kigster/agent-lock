# frozen_string_literal: true

module Agent
  module Lock
    module CLI
      module Commands
        # Give a scope back.
        class Release < Base
          desc "Release a lock you hold"

          argument :scope, required: true, desc: "The path or glob you locked"

          example ["workflow/**", "lib/agent/lock/cli.rb"]

          def call(scope:, **options)
            result = manager(options[:dir]).release(scope)

            case result.status
            when :released then say("RELEASED #{result.record.scope}")
            when :not_found then say("NOT LOCKED #{scope}")
            when :refused
              warn_("REFUSED — #{result.record.scope} is held by #{result.record.agent_id}, not you")
            end

            finish(result)
          end
        end
      end
    end
  end
end

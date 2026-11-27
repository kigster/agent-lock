# frozen_string_literal: true

require_relative "tree_command"

module Agent
  module Lock
    module CLI
      module Commands
        # Give a scope back.
        class Release < TreeCommand
          desc "Give back a lock you hold, thawing any files it froze"

          argument :scope, required: true, desc: "The path or glob you locked"

          example ["'lib/billing/**'", "lib/billing/tax.rb"]

          # @param scope [String] the scope exactly as it was claimed
          # @param options [Hash] `:dir`, `:locking_strategy`, `:redis_url`
          # @return [Manager::Result] :released, :not_found or :refused
          def call(scope:, **options)
            result = manager(options).release(scope)

            case result.status
            when :released then say("RELEASED #{result.record.scope}")
            when :not_found then say("NOT LOCKED #{scope}")
            when :refused
              warn_("REFUSED: #{result.record.scope} is held by #{result.record.agent_id}, not you")
            end

            finish(result)
          end
        end
      end
    end
  end
end

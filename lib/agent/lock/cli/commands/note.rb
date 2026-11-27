# frozen_string_literal: true

require_relative "tree_command"

module Agent
  module Lock
    module CLI
      module Commands
        # Write down where you are, in the lock itself.
        #
        # The lock and the notes have one lifespan on purpose. A machine that
        # reboots loses the session but not the file, so the next run reads one
        # document and knows what was underway and how far it got.
        class Note < TreeCommand
          desc "Append a timestamped progress note to a lock you hold"

          argument :scope, required: true, desc: "The scope exactly as you claimed it"
          argument :text, required: true, desc: "What just happened, for whoever resumes the work"

          example ["'lib/billing/**' 'totals done, specs still red'"]

          # @param scope [String]
          # @param text [String]
          # @param options [Hash] `:dir`, `:locking_strategy`, `:redis_url`
          # @return [Manager::Result] :noted, :not_found or :refused
          def call(scope:, text:, **options)
            result = manager(options).note(scope, text)

            case result.status
            when :noted then say("NOTED #{result.record.scope}")
            when :not_found then warn_("NOT LOCKED #{scope}, take the lock before writing in it")
            when :refused then warn_("REFUSED: #{result.record.scope} is held by #{result.record.agent_id}")
            end

            finish(result)
          end
        end
      end
    end
  end
end

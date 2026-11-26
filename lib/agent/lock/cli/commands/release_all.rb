# frozen_string_literal: true

require_relative "tree_command"

module Agent
  module Lock
    module CLI
      module Commands
        # What a session should run when it finishes, so the next one does not
        # have to work out whether it crashed.
        class ReleaseAll < TreeCommand
          desc "Release all locks of this session and its sub-agents"

          # @param options [Hash] `:dir`
          # @return [Manager::Result] with every record it released
          def call(**options)
            result = manager(options[:dir]).release_all
            result.records.each { |record| say("RELEASED #{record.scope}") }
            say("Released #{result.records.size} lock(s).")
            finish(result)
          end
        end
      end
    end
  end
end

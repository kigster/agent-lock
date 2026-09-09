# frozen_string_literal: true

module Agent
  module Lock
    module CLI
      module Commands
        # What a session should run when it finishes, so the next one does not
        # have to work out whether it crashed.
        class ReleaseAll < Base
          desc "Release every lock this session holds"

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

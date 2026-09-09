# frozen_string_literal: true

require_relative "base"

module Agent
  module Lock
    module CLI
      module Commands
        # What is installed, for a bug report.
        class Version < Base
          desc "Print the version"

          def call(**)
            say(Agent::Lock::VERSION)
          end
        end
      end
    end
  end
end

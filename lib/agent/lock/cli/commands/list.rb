# frozen_string_literal: true

require_relative "base"

module Agent
  module Lock
    module CLI
      module Commands
        # Everything in this tree's store, worktree siblings included, since
        # they share one `.git` and therefore one set of locks.
        class List < Base
          desc "Every live lock"

          option :json, type: :boolean, default: false, desc: "Machine-readable output"

          example ["", "--json"]

          def call(**options)
            result = manager(options[:dir]).list

            if result.records.empty?
              say(options[:json] ? "[]" : "No locks held.")
            else
              say("Locks held (#{result.records.size}):") unless options[:json]
              report_records(result.records, json: options[:json])
            end

            finish(result)
          end
        end
      end
    end
  end
end

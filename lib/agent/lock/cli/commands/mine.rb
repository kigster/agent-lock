# frozen_string_literal: true

require_relative "tree_command"

module Agent
  module Lock
    module CLI
      module Commands
        # What this session holds, and what its sub-agents hold, since those
        # are what its `release-all` would take with it. Never its parent's:
        # a sub-agent that saw those as its own could release them.
        class Mine < TreeCommand
          desc "Locks held by this session and its sub-agents"

          option :json, type: :boolean, default: false, desc: "Print the records as a JSON array"

          example ["", "--json"]

          # @param options [Hash] `:dir`, `:locking_strategy`, `:redis_url`, `:json`
          # @return [Manager::Result]
          def call(**options)
            manager = manager(options)
            result = manager.mine

            if result.records.empty?
              say(options[:json] ? "[]" : "No locks held by #{manager.identity.id}.")
            else
              report_records(result.records, json: options[:json], stale_minutes: manager.stale_minutes)
            end

            finish(result)
          end
        end
      end
    end
  end
end

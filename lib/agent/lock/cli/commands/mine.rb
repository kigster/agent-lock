# frozen_string_literal: true

require_relative "base"

module Agent
  module Lock
    module CLI
      module Commands
        # What this session holds. A sub-agent sees its parent's locks as its
        # own, which is the point: they are one agent as far as writing goes.
        class Mine < Base
          desc "Locks held by this session"

          option :json, type: :boolean, default: false, desc: "Machine-readable output"

          def call(**options)
            manager = manager(options[:dir])
            result = manager.mine

            if result.records.empty?
              say(options[:json] ? "[]" : "No locks held by #{manager.identity.id}.")
            else
              report_records(result.records, json: options[:json])
            end

            finish(result)
          end
        end
      end
    end
  end
end

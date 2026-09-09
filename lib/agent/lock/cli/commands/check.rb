# frozen_string_literal: true

module Agent
  module Lock
    module CLI
      module Commands
        # Ask before writing. Exits 1 when anything overlapping is held, so a
        # shell script can gate on it without parsing anything.
        class Check < Base
          desc "Say who holds a path; exits 1 if it is held"

          argument :scope, required: true, desc: "A path, a directory, or a glob"

          option :json, type: :boolean, default: false, desc: "Machine-readable output"

          example ["workflow/**", "lib/agent/lock/cli.rb --json"]

          def call(scope:, **options)
            result = manager(options[:dir]).check(scope)

            case result.status
            when :free then say(options[:json] ? "[]" : "FREE #{scope}")
            when :mine
              # Held, but by you: safe to write, and worth saying which of your
              # own locks covers it rather than a bare "free".
              report_records(result.records, json: options[:json])
              say("YOURS #{result.record.scope}") unless options[:json]
            when :held
              options[:json] ? report_records(result.records, json: true) : report_held(result.records)
            end

            finish(result)
          end
        end
      end
    end
  end
end

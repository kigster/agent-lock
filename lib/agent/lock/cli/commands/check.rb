# frozen_string_literal: true

require_relative "base"

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

          # @param scope [String]
          # @param options [Hash]
          # @return [Manager::Result]
          def call(scope:, **options)
            manager = manager(options[:dir])
            result = manager.check(scope)
            report(result, scope, json: options[:json], stale_minutes: manager.stale_minutes)
            finish(result)
          end

          private

          # @param result [Manager::Result]
          # @param scope [String] as the user typed it
          # @param json [Boolean]
          # @param stale_minutes [Integer]
          def report(result, scope, json:, stale_minutes:)
            case result.status
            when :free then say(json ? "[]" : "FREE #{scope}")
            when :mine
              # Held, but by you: safe to write, and worth saying which of your
              # own locks covers it rather than a bare "free".
              report_records(result.records, json: json, stale_minutes: stale_minutes)
              say("YOURS #{result.record.scope}") unless json
            when :held
              if json
                report_records(result.records, json: true, stale_minutes: stale_minutes)
              else
                report_held(result.records, stale_minutes: stale_minutes)
              end
            end
          end
        end
      end
    end
  end
end

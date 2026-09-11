# frozen_string_literal: true

require_relative "base"

module Agent
  module Lock
    module CLI
      module Commands
        # Claim a scope, or find out who has it.
        class Acquire < Base
          desc "Claim a path or glob; exits 1 if somebody else holds it"

          argument :scope, required: true, desc: "A path, a directory, or a glob such as 'workflow/**'"
          argument :intent, required: false, desc: "What you are about to do, for whoever reads the lock"

          option :enforce, type: :boolean, default: false,
                           desc: "Also make the matched files unwritable (macOS)"
          option :force, type: :boolean, default: false,
                         desc: "Allow --enforce on a very wide scope"

          example [
            "workflow/** 'rewriting the installer'",
            "lib/agent/lock/cli.rb 'adding the json flag'",
            "'**' 'a migration that touches everything'"
          ]

          # @param scope [String]
          # @param intent [String, nil]
          # @param options [Hash]
          # @return [Manager::Result]
          def call(scope:, intent: nil, **options)
            manager = manager(options[:dir])
            result = manager.acquire(
              scope, intent: intent || "unspecified",
                     enforce: options[:enforce], force: options[:force]
            )

            report(result, manager.stale_minutes)
            finish(result)
          end

          private

          # @param result [Manager::Result]
          # @param stale_minutes [Integer]
          def report(result, stale_minutes)
            case result.status
            when :acquired then report_acquired(result)
            when :already_mine then say("ALREADY YOURS #{result.record.scope}")
            when :held
              warn_("REFUSED, do not write here")
              report_held(result.records, stale_minutes: stale_minutes)
            when :interrupted then report_interrupted(result.record)
            end
          end

          def report_acquired(result)
            record = result.record
            say("ACQUIRED #{record.scope}  (holder: #{record.agent_id})")
            say("FROZEN   #{record.frozen_paths.size} file(s)") if record.frozen_paths.any?
            warn_(result.message) if result.message
          end

          # An orphan is somebody's unfinished work, so the two ways out of it
          # are spelled out rather than left to be looked up.
          #
          # @param record [Record] the orphaned lock on this exact scope
          def report_interrupted(record)
            warn_("INTERRUPTED WORK on #{record.scope}, left by #{record.agent_id}")
            advise_interrupted(record)
          end
        end
      end
    end
  end
end

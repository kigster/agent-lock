# frozen_string_literal: true

require_relative "tree_command"

module Agent
  module Lock
    module CLI
      module Commands
        # Claim a scope, or find out who has it.
        class Acquire < TreeCommand
          desc "Claim a path or glob before writing; exit 1 if another agent has it"

          argument :scope, required: true, desc: "A path, a directory, or a glob such as 'lib/**'"
          argument :intent, required: false, desc: "What you are about to do, for whoever reads the lock"

          option :enforce, type: :boolean, default: false,
                           desc: "Also freeze the matched files with chflags uchg (macOS only)"
          option :allow_wide, type: :boolean, default: false,
                              desc: "Let --enforce freeze more than #{Freeze::LIMIT} files"

          example [
            "'lib/billing/**' 'rewriting the invoices'",
            "lib/billing/tax.rb 'fixing the rounding'",
            "'config/credentials/**' 'keys must not move' --enforce"
          ]

          # @param scope [String] as typed: a path, a directory or a glob
          # @param intent [String, nil] what the holder is about to do
          # @param options [Hash] `:dir`, `:enforce`, `:allow_wide`
          # @return [Manager::Result]
          def call(scope:, intent: nil, **options)
            manager = manager(options[:dir])
            result = manager.acquire(
              scope, intent: intent || "unspecified",
                     enforce: options[:enforce], wide: options[:allow_wide]
            )

            report(result, manager.stale_minutes)
            finish(result)
          end

          private

          # @param result [Manager::Result]
          # @param stale_minutes [Integer]
          # @return [void]
          def report(result, stale_minutes)
            case result.status
            when :acquired then report_acquired(result)
            when :already_mine then say("ALREADY YOURS #{result.record.scope}")
            when :held
              warn_("REFUSED, do not write here")
              warn_(result.message) if result.message
              report_held(result.records, stale_minutes: stale_minutes)
            when :interrupted then report_interrupted(result.record)
            when :parent_scope then report_parent_scope(result.record)
            end
          end

          # A refusal no amount of waiting fixes, so it says what will work
          # instead. Locks are keyed by scope, which makes the parent's record
          # the very one this child would have to write.
          #
          # @param record [Record] the parent's lock on this exact scope
          # @return [void]
          def report_parent_scope(record)
            warn_("REFUSED: #{record.scope} is your parent's (#{record.agent_id}) whole claim; " \
                  "claim a narrower scope inside it")
          end

          # @param result [Manager::Result] an :acquired result
          # @return [void]
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
          # @return [void]
          def report_interrupted(record)
            warn_("INTERRUPTED WORK on #{record.scope}, left by #{record.agent_id}")
            advise_interrupted(record)
          end
        end
      end
    end
  end
end

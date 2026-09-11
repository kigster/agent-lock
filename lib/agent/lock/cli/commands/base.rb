# frozen_string_literal: true

require "dry/cli"
require_relative "../../manager"

require "json"

module Agent
  module Lock
    module CLI
      module Commands
        # What every command shares: the launcher it prints through, the
        # manager it delegates to, and the wording of a held lock.
        #
        # Nothing here calls `puts` or `exit`. Output goes to the launcher's
        # streams and the exit code is handed back to it, which is what lets
        # the whole CLI run inside the test process.
        class Base < Dry::CLI::Command
          # Inherited by every command, so `--dir` works everywhere without
          # each one restating it.
          def self.inherited(subclass)
            super
            subclass.option :dir, type: :string, default: ".",
                                  desc: "Work as if run from this directory"
          end

          attr_reader :launcher

          # @param launcher [Launcher]
          def initialize(launcher = nil)
            super()
            @launcher = launcher
          end

          private

          def stdout = launcher.stdout

          def stderr = launcher.stderr

          # What to call this CLI in a hint, so the command it suggests is
          # one the user can paste back: `alo` for somebody who typed `alo`.
          #
          # @return [String]
          def program = launcher.program

          # @param dir [String]
          # @return [Manager]
          def manager(dir) = Manager.new(tree: Tree.for(dir || "."))

          # @param text [String]
          def say(text) = stdout.puts(text)

          def warn_(text) = stderr.puts(text)

          # @param result [Manager::Result]
          def finish(result)
            launcher.exit_code = result.code
            result
          end

          # The one message worth getting right: an agent that hits a lock
          # should learn who has it, since when, and what they are doing, so it
          # can decide whether to wait or to work somewhere else. A stale
          # holder changes that decision, from waiting to asking somebody, so
          # it is said outright rather than left to be worked out from a date.
          #
          # @param records [Array<Record>]
          # @param stale_minutes [Integer] Manager#stale_minutes
          def report_held(records, stale_minutes:)
            records.each do |record|
              warn_(["HELD  #{record.scope}  by #{record.agent_id}  since #{record.created_at}",
                     tag_for(record, stale_minutes)].compact.join("  "))
              warn_("      intent: #{record.intent}") unless record.intent.empty?
              warn_("      frozen: #{record.frozen_paths.size} file(s)") if record.frozen_paths.any?
              warn_stale(record, stale_minutes) if record.stale?(stale_minutes)
            end
          end

          # One line per record, tagged, so that a line lifted out by `grep`
          # still says whether it is a claim in good standing.
          #
          # @param records [Array<Record>]
          # @param json [Boolean]
          # @param stale_minutes [Integer] Manager#stale_minutes
          def report_records(records, json:, stale_minutes:)
            return say(JSON.pretty_generate(records.map { |record| as_json(record, stale_minutes) })) if json

            records.each do |record|
              say([record.scope, record.agent_id, record.created_at, tag_for(record, stale_minutes)].compact.join("\t"))
              say("  #{record.intent}") unless record.intent.empty?
            end
          end

          # The two ways out of an interrupted lock, spelled out rather than
          # left to be looked up, since each throws away something different.
          #
          # @param record [Record] an orphaned lock
          def advise_interrupted(record)
            warn_("  #{program} resume #{record.scope}   # take it back, notes and all")
            warn_("  #{program} break #{record.scope}    # throw it away and start over")
          end

          # @param record [Record]
          # @param stale_minutes [Integer]
          # @return [String, nil] INTERRUPTED, STALE, or nil for a claim in good standing
          def tag_for(record, stale_minutes)
            return "INTERRUPTED" if record.orphaned?

            "STALE" if record.stale?(stale_minutes)
          end

          # A stale holder is not a dead one: a holder that died on this machine
          # is reaped on its own, so this one is most likely still running and
          # merely quiet. Breaking it is a decision somebody announces, never a
          # default.
          #
          # @param record [Record]
          # @param stale_minutes [Integer]
          def warn_stale(record, stale_minutes)
            warn_("      stale: untouched for over #{stale_minutes} minutes; ask its holder, " \
                  "or announce it before `#{program} break #{record.scope}`")
          end

          # `stale` is computed, not stored, so it is added here; `status`
          # already says whether a record is interrupted.
          #
          # @param record [Record]
          # @param stale_minutes [Integer]
          # @return [Hash]
          def as_json(record, stale_minutes)
            Record::FIELDS.to_h { |field| [field, record.public_send(field)] }
                          .merge(intent: record.intent, stale: record.stale?(stale_minutes))
          end
        end
      end
    end
  end
end

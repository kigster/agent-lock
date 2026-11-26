# frozen_string_literal: true

require "dry/cli"
require_relative "../../manager"

require "json"

module Agent
  module Lock
    module CLI
      # One class per `alock` verb, all built on {Base}.
      module Commands
        # What every command shares: the launcher it prints through, the
        # manager it delegates to, and the wording of a held lock.
        #
        # Nothing here calls `puts` or `exit`. Output goes to the launcher's
        # streams and the exit code is handed back to it, which is what lets
        # the whole CLI run inside the test process.
        #
        # Commands that read or write a lock store subclass {TreeCommand}
        # instead, which adds `--dir`. The rest (`version`, `whoami`,
        # `skills`) never look at a tree, so offering them `--dir` would be
        # a flag that silently does nothing.
        #
        # @abstract Subclass and implement `#call(**options)`.
        class Base < Dry::CLI::Command
          # @return [Launcher] the streams, program name and exit code holder
          attr_reader :launcher

          # @param launcher [Launcher]
          def initialize(launcher = nil)
            super()
            @launcher = launcher
          end

          private

          # @return [IO] where the deliverable goes
          def stdout = launcher.stdout

          # @return [IO] where refusals, hints and warnings go
          def stderr = launcher.stderr

          # What to call this CLI in a hint, so the command it suggests is
          # one the user can paste back: `alock` for somebody who typed `alock`.
          #
          # @return [String]
          def program = launcher.program

          # @param dir [String, nil] the `--dir` option; nil means the current directory
          # @return [Manager] bound to the tree that contains `dir`
          def manager(dir)
            tree = Tree.for(dir || ".")
            Manager.new(tree: tree, **manager_overrides(tree))
          end

          # Hooks {Facade} sets on the launcher. All nil when the command
          # line runs, so this adds nothing to that path.
          #
          # @param tree [Tree]
          # @return [Hash]
          def manager_overrides(tree)
            overrides = {}
            overrides[:store] = launcher.store_for.call(tree) if launcher.store_for
            overrides[:identity] = launcher.identity if launcher.identity
            overrides[:stale_minutes] = launcher.stale_minutes unless launcher.stale_minutes.nil?
            overrides
          end

          # @param text [String] one line of the deliverable
          # @return [void]
          def say(text) = stdout.puts(text)

          # STDOUT is flushed first. An agent harness reads both streams down
          # one pipe, where STDOUT is block-buffered and STDERR is not, and
          # without the flush every hint arrives ahead of the record it is
          # about.
          #
          # @param text [String] one line of diagnostics
          # @return [void]
          def warn_(text)
            stdout.flush
            stderr.puts(text)
          end

          # Hand the result's exit code to the launcher, which exits with it.
          #
          # @param result [Manager::Result, Skill::Result]
          # @return [Manager::Result, Skill::Result] the same result
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
          # @return [void]
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
          # @return [void]
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
          # @return [void]
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
          # @return [void]
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

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
          # can decide whether to wait or to work somewhere else.
          #
          # @param records [Array<Record>]
          def report_held(records)
            records.each do |record|
              warn_("HELD  #{record.scope}  by #{record.agent_id}  since #{record.created_at}")
              warn_("      intent: #{record.intent}") unless record.intent.empty?
              warn_("      frozen: #{record.frozen_paths.size} file(s)") if record.frozen_paths.any?
            end
          end

          # @param records [Array<Record>]
          def report_records(records, json:)
            return say(JSON.pretty_generate(records.map { |record| as_json(record) })) if json

            records.each do |record|
              say("#{record.scope}\t#{record.agent_id}\t#{record.created_at}")
              say("  #{record.intent}") unless record.intent.empty?
            end
          end

          def as_json(record)
            Record::FIELDS.to_h { |field| [field, record.public_send(field)] }.merge(intent: record.intent)
          end
        end
      end
    end
  end
end

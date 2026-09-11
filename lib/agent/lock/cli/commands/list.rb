# frozen_string_literal: true

require_relative "base"

module Agent
  module Lock
    module CLI
      module Commands
        # Everything in this tree's store, worktree siblings included, since
        # they share one `.git` and therefore one set of locks.
        #
        # Live claims and interrupted work are listed apart. An orphan blocks
        # nobody, so counting it as held told a reader the tree was busier
        # than it was, and gave them no way to see which locks were real.
        class List < Base
          desc "Every live lock, and any interrupted work"

          option :json, type: :boolean, default: false, desc: "Machine-readable output"

          example ["", "--json"]

          # @param options [Hash]
          # @return [Manager::Result]
          def call(**options)
            manager = manager(options[:dir])
            result = manager.list

            if options[:json]
              report_records(result.records, json: true, stale_minutes: manager.stale_minutes)
            else
              report_listing(result.records, manager.stale_minutes)
            end

            finish(result)
          end

          private

          # @param records [Array<Record>]
          # @param stale_minutes [Integer]
          def report_listing(records, stale_minutes)
            held, interrupted = records.partition(&:active?)

            if held.empty?
              say("No locks held.")
            else
              say("Locks held (#{held.size}):")
              report_records(held, json: false, stale_minutes: stale_minutes)
            end

            report_interrupted(interrupted, stale_minutes) if interrupted.any?
          end

          # Each orphan is followed by its two ways out, on STDERR, so what
          # goes down a pipe is the listing alone.
          #
          # @param records [Array<Record>] orphaned locks
          # @param stale_minutes [Integer]
          def report_interrupted(records, stale_minutes)
            say("Interrupted (#{records.size}):")
            records.each do |record|
              report_records([record], json: false, stale_minutes: stale_minutes)
              advise_interrupted(record)
            end
          end
        end
      end
    end
  end
end

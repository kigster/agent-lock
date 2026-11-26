# frozen_string_literal: true

require_relative "../error"

module Agent
  module Lock
    class Facade
      # Raises {Refused} for a result the command line would have refused,
      # and hands every other result back unchanged.
      #
      # The message says what the CLI says on stderr, worded for a log
      # line: who holds the scope and what to do instead.
      module Refusal
        # One message per refusing status. `scope` is the scope as the caller
        # typed it, for the one status (`:not_found`) that has no record.
        MESSAGES = {
          held: lambda { |result, _scope|
            ["REFUSED, do not write here", *result.records.map { |record| Refusal.held_line(record) }].join("\n")
          },
          parent_scope: lambda { |result, _scope|
            "REFUSED: #{result.record.scope} is your parent's (#{result.record.agent_id}) whole claim; " \
              "claim a narrower scope inside it"
          },
          interrupted: lambda { |result, _scope|
            "INTERRUPTED WORK on #{result.record.scope}, left by #{result.record.agent_id}; resume it or break it"
          },
          refused: lambda { |result, _scope|
            "REFUSED: #{result.record.scope} is held by #{result.record.agent_id}, not you"
          },
          not_found: ->(_result, scope) { "NOT LOCKED #{scope}, take the lock before writing in it" },
          differs: lambda { |result, _scope|
            "REFUSED: #{result.path} differs from the copy this gem ships; pass overwrite: true to replace it"
          },
          linked: lambda { |result, _scope|
            "REFUSED: #{result.path} is a symlink, so something else installs it; left alone"
          }
        }.freeze

        # Refused by every verb that can return them. `:not_found` is not:
        # releasing or breaking a free scope is a success.
        REFUSING = %i[held parent_scope interrupted refused differs linked].freeze

        module_function

        # @param result [Manager::Result, Skill::Result]
        # @param scope [String, nil] as the caller typed it
        # @param also [Array<Symbol>] statuses this verb refuses on top of {REFUSING}
        # @return [Manager::Result, Skill::Result] the same result, when it is not a refusal
        # @raise [Refused] when it is
        def check!(result, scope: nil, also: [])
          return result unless REFUSING.include?(result.status) || also.include?(result.status)

          raise Refused.new(MESSAGES.fetch(result.status).call(result, scope), result: result)
        end

        # @param record [Record]
        # @return [String] e.g. "HELD  lib/**  by luke  since 2026-11-25T10:00:00Z  intent: billing"
        def held_line(record)
          line = "HELD  #{record.scope}  by #{record.agent_id}  since #{record.created_at}"
          record.intent.empty? ? line : "#{line}  intent: #{record.intent}"
        end
      end
    end
  end
end

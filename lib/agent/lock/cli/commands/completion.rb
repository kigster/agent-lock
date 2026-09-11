# frozen_string_literal: true

require "dry/cli/autocomplete/command"

module Agent
  module Lock
    module CLI
      module Commands
        # `alo completion bash|zsh`, from dry-cli-autocomplete, with the two
        # things that gem's command cannot do for us restated here.
        #
        # It writes to `$stdout` directly, which the in-process launcher can
        # neither capture nor redirect, and it binds a registry by way of
        # `Class.new`, which is exactly where dry-cli clears an inherited
        # `desc` and `example`. Both belong upstream; until then, here.
        class Completion < Dry::CLI::Autocomplete::Command
          desc "Print a shell completion script for bash or zsh"

          # Spelled out rather than taken from $PROGRAM_NAME, which under a
          # test runner names the runner, and which upstream reads at load
          # time anyway.
          example [
            "bash > \"$(brew --prefix)/etc/bash_completion.d/alo\"",
            "zsh  > \"${fpath[1]}/_alo\""
          ]

          # Binding a registry subclasses this command, and dry-cli's
          # `inherited` hook starts every subclass with no description and no
          # examples. Arguments and options survive it; those two do not, so
          # they are copied across by hand.
          #
          # @param registry [Dry::CLI::Registry]
          # @return [Class]
          def self.[](registry, program_name: nil)
            super.tap do |bound|
              bound.desc(description)
              bound.example(*examples)
            end
          end

          private

          # dry-cli hands every command the stream it should be writing to.
          # The command upstream ignores it; this one does not.
          def out = @out || $stdout
        end
      end
    end
  end
end

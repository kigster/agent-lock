# frozen_string_literal: true

require "dry/cli/autocomplete/command"

module Agent
  module Lock
    module CLI
      module Commands
        # `alock completion bash|zsh`, from dry-cli-autocomplete.
        #
        # Upstream binds a registry by subclassing this command, restores
        # the description and examples dry-cli's `inherited` hook clears, and
        # writes to the stream dry-cli hands it. All that is left to say here
        # is the wording, and where a Homebrew bash keeps its completions.
        class Completion < Dry::CLI::Autocomplete::Command
          desc "Print a bash or zsh completion script"

          # Upstream calls this from inside the subclass it builds, so
          # overriding it here changes the examples `--help` prints.
          #
          # @param name [String] the program the script completes
          # @return [Array<String>]
          def self.examples_for(name)
            [
              "bash > \"$(brew --prefix)/etc/bash_completion.d/#{name}\"",
              "zsh  > \"${fpath[1]}/_#{name}\""
            ]
          end
        end
      end
    end
  end
end

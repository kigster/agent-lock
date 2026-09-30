# frozen_string_literal: true

require_relative "manager"
require_relative "version"
require "dry/cli"
require "dry/cli/help"

module Agent
  module Lock
    # The command line, and nothing else. Every command here is a thin shell:
    # parse flags, call one Manager method, print the result, set an exit code.
    # No command decides anything a library object could decide instead.
    module CLI
      # What the gem is installed as. Taken from the gemspec's one executable
      # rather than from $PROGRAM_NAME, which under a test runner is the
      # runner. The completion script it emits names the program in every
      # line, so guessing it wrong is not a cosmetic mistake.
      PROGRAM_NAME = "alock"

      # What `alock -h` says before it lists the commands. Wrapped by
      # dry-cli-help at HELP_WIDTH rather than the terminal's width, so the
      # screen reads the same in a wide terminal, a narrow one, and a log.
      HELP_WIDTH = 85

      DESCRIPTION = <<~TEXT
        Advisory locks for AI coding agents working concurrently in one checkout.
        An agent claims the file or directory it is about to write, and every other
        agent that checks sees who holds it and why. Nothing is enforced: the locks
        work because every agent checks before it writes.

        Locks live in one of two backends. Redis, when one answers on REDIS_URL or
        on localhost:6379, holds across machines and can expire an abandoned lock.
        The file store, used when no Redis answers, needs nothing installed. The
        first process in a tree records which backend it chose, and every later
        process in that tree stays on it. Set AGENT_LOCK_BACKEND to `redis` or
        `file` to choose one yourself.
      TEXT

      Dry::CLI::Help.configure do
        title "Agent Lock, Version #{Agent::Lock::VERSION}"
        description DESCRIPTION
        epilogue "Documentation: https://github.com/kigster/agent-lock"
        width HELP_WIDTH
      end

      # A registry whose commands are already bound to this launcher, so a
      # command writes to the streams it was given rather than to the process's.
      #
      # @param launcher [Launcher]
      # @return [Dry::CLI::Registry]
      def self.registry_for(launcher)
        # `extend` and `register` have to be sent to the new class explicitly.
        # Inside a `tap` block `self` is still this module, so writing them
        # bare turned Agent::Lock::CLI itself into the registry, handed back a
        # class that knew no commands, and left the completion command bound
        # to that empty class.
        registry = Class.new { extend Dry::CLI::Registry }

        COMMANDS.each do |name, (klass, aliases)|
          registry.register(name, klass.new(launcher), aliases: aliases)
        end

        registry.register("completion", Commands::Completion[registry, program_name: PROGRAM_NAME])
        registry
      end

      # The whole command line, in one place, so adding a verb is one line
      # rather than three. Filled in below, once the commands are loaded.
    end
  end
end

require_relative "cli/commands/base"
require_relative "cli/commands/acquire"
require_relative "cli/commands/release"
require_relative "cli/commands/check"
require_relative "cli/commands/list"
require_relative "cli/commands/mine"
require_relative "cli/commands/release_all"
require_relative "cli/commands/break"
require_relative "cli/commands/note"
require_relative "cli/commands/resume"
require_relative "cli/commands/whoami"
require_relative "cli/commands/skill"
require_relative "cli/commands/version"
require_relative "cli/commands/completion"

module Agent
  module Lock
    module CLI
      COMMANDS = {
        "acquire" => [Commands::Acquire, []],
        "release" => [Commands::Release, []],
        "check" => [Commands::Check, []],
        "list" => [Commands::List, ["ls"]],
        "mine" => [Commands::Mine, []],
        "release-all" => [Commands::ReleaseAll, []],
        "break" => [Commands::Break, []],
        "note" => [Commands::Note, []],
        "resume" => [Commands::Resume, []],
        "whoami" => [Commands::Whoami, []],
        "skill path" => [Commands::SkillPath, []],
        "skill install" => [Commands::SkillInstall, []],
        "version" => [Commands::Version, %w[-v --version]]
      }.freeze
    end
  end
end

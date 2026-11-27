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

      # Colours the help text. Pastel honours NO_COLOR and a non-terminal
      # stdout, so piped help and the specs read plain text.
      COLORS = Pastel.new

      # The name in the left cell of the help's title box.
      TITLE = "    Agent/Lock — Distributed Advisory Locker"

      # Inner widths of the title box's two cells. The version is padded to
      # the right one rather than spaced by hand, so 4.10.0 still closes the box.
      TITLE_CELLS = [45, 33].freeze

      # The three lines `alock -h` opens with: the gem's name and its version, boxed.
      #
      # @param version [String]
      # @return [String]
      def self.title_box(version = Agent::Lock::VERSION)
        left, right = TITLE_CELLS
        rule = ->(open, middle, close) { "#{open}#{"━" * left}#{middle}#{"━" * right}#{close}" }
        name = COLORS.yellow(TITLE.ljust(left))
        release = COLORS.green.bold(" Version #{version}".ljust(right))

        [rule.call("┏", "┳", "┓"), "┃#{name}┃#{release}┃", rule.call("┗", "┻", "┛")].join("\n")
      end
      # The column dry-cli-help wraps at, rather than the terminal's width,
      # so help reads the same in a wide terminal, a narrow one, and a log.
      HELP_WIDTH = 85

      # What `alock -h` says before it lists the commands.
      DESCRIPTION = <<~TEXT.freeze
        Advisory locks for AI coding agents that share a checkout, or a branch
        across worktrees and optionally across machines. Claim the file, directory
        or glob you are about to write to with `acquire`; any other agent that claims
        or checks an overlapping scope is refused and told who holds it, since when,
        and why. Locks are advisory only: #{COLORS.blue("they protect agents from working on the same files as other agents that also check for locks")}.

        Sub-agents of one session share its process, so each must name itself on
        every call: #{COLORS.blue("AGENT_ID=<name> alock acquire ...")} Run `alock whoami` to see the
        name your locks would carry.

        Backends: Redis when one answers on env REDIS_URL (shared across machines),
        or localhost:6379 (local only). Otherwise a file store inside .git (also
        local only). The first process in a checkout records the choice; setting environment
        variable #{COLORS.blue("AGENT_LOCK_BACKEND=redis|file")} overrides it.

        Exit codes: 0 done, 1 refused or held by someone else, 2 could not run.

        If you are using the gem from a Ruby application, you should default to the Ruby
        API. Every CLI command is available via Ruby API, as described in the README:
        #{COLORS.cyan.bold.underline("https://github.com/kigster/agent-lock#ruby-api")}
      TEXT

      Dry::CLI::Help.configure do
        styles { heading :bold, :magenta }
        title "\n#{CLI.title_box}"
        description DESCRIPTION
        epilogue "Documentation: #{COLORS.cyan.bold.underline("https://github.com/kigster/agent-lock")}"
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

      # The whole command line is the COMMANDS table below, filled in once
      # the command classes are loaded, so adding a verb is one line.
    end
  end
end

require_relative "cli/commands/base"
require_relative "cli/commands/tree_command"
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
require_relative "cli/commands/skills"
require_relative "cli/commands/version"
require_relative "cli/commands/completion"

module Agent
  module Lock
    module CLI
      # Every command but `completion`, which needs the finished registry.
      # Each entry maps the name typed to its class and its aliases.
      #
      # @return [Hash{String => Array(Class, Array<String>)}]
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
        "skills path" => [Commands::SkillsPath, []],
        "skills install" => [Commands::SkillsInstall, []],
        "version" => [Commands::Version, %w[-v --version]]
      }.freeze
    end
  end
end

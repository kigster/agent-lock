# frozen_string_literal: true

require "forwardable"
require "pastel"
require "dry/cli"

require_relative "cli"

module Agent
  module Lock
    # The one place this gem touches the outside world.
    #
    # Streams and Kernel arrive as arguments so a test can pass its own and
    # read back what happened. Nothing below this class may call `puts`, touch
    # STDOUT, or call `exit` without a receiver: do that and the suite either
    # cannot see the output or dies in the middle of an example. Aruba's
    # in-process launcher expects exactly this shape, which is what makes the
    # end-to-end specs fast enough to run on every save.
    class Launcher
      DEFAULT_PROGRAM = "agent-lock"

      extend Forwardable

      def_delegators :@pastel, :red, :green, :yellow, :blue, :magenta, :cyan, :white,
                     :bg_black, :bg_red, :bg_green, :bg_yellow, :bg_blue, :bg_magenta, :bg_cyan, :bg_white,
                     :bold, :underline, :italic, :strikethrough

      attr_accessor :argv, :stdin, :stdout, :stderr, :kernel, :pastel

      # What a command asked the process to exit with. Commands set it rather
      # than exiting, so that one `kernel.exit` in `ensure` is the only way out.
      #
      # @return [Integer, nil]
      attr_accessor :exit_code

      # The name the user typed, `alock` or `agent-lock`, for every hint and
      # error prefix. A hint naming the other one may not be on the PATH, or
      # may be the old shell script that shadows this gem's `agent-lock`.
      #
      # @return [String]
      attr_reader :program

      # The positional signature is fixed by what Aruba's in-process launcher
      # constructs, and by the pattern it comes from, so the cop loses this
      # one. The program name is a keyword so that Aruba, which knows nothing
      # of it, still gets a working default.
      #
      # It is handed in rather than read from `$PROGRAM_NAME` here, because
      # under the test runner that says `rspec`.
      #
      # @param argv [Array<String>]
      # @param program [String] e.g. `File.basename($PROGRAM_NAME)`
      # rubocop:disable-next Metrics/ParameterLists
      def initialize(argv = ARGV,
                     stdin = $stdin,
                     stdout = $stdout,
                     stderr = $stderr,
                     kernel = Kernel,
                     pastel = Pastel.new(enabled: stdout.respond_to?(:tty?) && stdout.tty?),
                     program: DEFAULT_PROGRAM)
        self.argv   = Array(argv)
        self.stdin  = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.kernel = kernel
        self.pastel = pastel
        @program    = program
      end

      # @return [void] always exits, with 0 unless something said otherwise
      # rubocop:disable-next Metrics/AbcSize
      def execute!
        backend_banner if %w[-h --help].intersect?(argv)

        code = 0
        Dry::CLI.new(CLI.registry_for(self)).call(arguments: argv, out: stdout, err: stderr)
      rescue SystemExit => e
        # dry-cli exits directly for `--help` and for a bad flag. Catching it
        # keeps that from taking the whole test process down with it.
        code = e.status
      rescue Dry::CLI::Error, Error => e
        stderr.puts(bold(red("ERROR: #{program}: #{e.message}")))
        code = 2
      rescue Interrupt
        stderr.puts(bold(yellow("WARNING: #{program}: interrupted")))
        code = 130
      ensure
        kernel.exit(exit_code || code)
      end

      private

      def p(msg = "")
        stdout.puts(msg)
      end

      # The two backends, ahead of dry-cli's own `--help` for each command, so
      # a reader learns the shape of the choice before any subcommand's flags.
      #
      # @return [void]
      # rubocop:disable-next Metrics/AbcSize
      def backend_banner
        p(bold(yellow("Agent Lock, Version #{green(Agent::Lock::VERSION)}")))
        p
        p(bold(blue("Usage:")))
        p("    alock [command [ subcommand ]] [options]")
        p
        p(bold(blue("Description:")))
        p("    This is a CLI utility aimed at the agents working concurrently in the same")
        p("    environment, sharing filesystem, worktrees, etc. Agent Lock allows fine-grained")
        p("    and effective locking, and can use multiple backends to store and maintain locks.")
        p
        p(cyan("    • Redis-Based Locking"))
        p("      This mechanism uses locally running Redis instance to coordinate access to shared")
        p("      resources (default, if Redis is available and accessible).")
        p
        p(cyan("    • File System Locking"))
        p("      This mechanism uses file system locks to coordinate access to shared resources.")
        p
        p("    You can set the environment variable #{yellow("AGENT_LOCK_BACKEND")} to either")
        p("    'redis' or 'file' to override the default.")
        p
      end
    end
  end
end

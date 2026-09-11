# frozen_string_literal: true

require_relative "cli"

require "dry/cli"

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

      attr_accessor :argv, :stdin, :stdout, :stderr, :kernel

      # The name the user typed, `alo` or `agent-lock`, for every hint and
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
      # rubocop:disable Metrics/ParameterLists
      def initialize(argv = ARGV, stdin = $stdin, stdout = $stdout, stderr = $stderr, kernel = Kernel,
                     program: DEFAULT_PROGRAM)
        self.argv = Array(argv)
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.kernel = kernel
        @program = program
      end
      # rubocop:enable Metrics/ParameterLists

      # @return [void] always exits, with 0 unless something said otherwise
      def execute!
        code = 0
        Dry::CLI.new(CLI.registry_for(self)).call(arguments: argv, out: stdout, err: stderr)
      rescue SystemExit => e
        # dry-cli exits directly for `--help` and for a bad flag. Catching it
        # keeps that from taking the whole test process down with it.
        code = e.status
      rescue Dry::CLI::Error, Error => e
        stderr.puts("#{program}: #{e.message}")
        code = 2
      rescue Interrupt
        stderr.puts("#{program}: interrupted")
        code = 130
      ensure
        kernel.exit(exit_code || code)
      end

      # What a command asked the process to exit with. Commands set it rather
      # than exiting, so that one `kernel.exit` in `ensure` is the only way out.
      #
      # @return [Integer, nil]
      attr_accessor :exit_code
    end
  end
end

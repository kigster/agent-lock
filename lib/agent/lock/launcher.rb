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
      attr_accessor :argv, :stdin, :stdout, :stderr, :kernel

      # The signature is fixed by what Aruba's in-process launcher constructs,
      # and by the pattern it comes from, so the cop loses this one.
      #
      # @param argv [Array<String>]
      # rubocop:disable Metrics/ParameterLists
      def initialize(argv = ARGV, stdin = $stdin, stdout = $stdout, stderr = $stderr, kernel = Kernel)
        self.argv = Array(argv)
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.kernel = kernel
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
        stderr.puts("agent-lock: #{e.message}")
        code = 2
      rescue Interrupt
        stderr.puts("agent-lock: interrupted")
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

# frozen_string_literal: true

require "stringio"
require_relative "../identity"
require_relative "../launcher"

module Agent
  module Lock
    class Facade
      # Runs one command object in this process.
      #
      # The command writes the same lines it would have written for `alock`.
      # Those lines are captured. A non-zero exit whose explanation went to
      # stderr is raised as {Refused}, with that text as the message. A
      # result the command prints on stdout is returned as the command
      # returned it.
      class Runner
        # Flags that choose who is asking and which tree, rather than
        # arguments of one verb.
        SESSION = %i[agent_id parent_id stale_minutes].freeze

        # @param backend [Backend]
        # @param agent_id [String, nil]
        # @param parent_id [String, nil]
        # @param stale_minutes [Integer, nil]
        def initialize(backend, agent_id: nil, parent_id: nil, stale_minutes: nil)
          @backend = backend
          @agent_id = agent_id
          @parent_id = parent_id
          @stale_minutes = stale_minutes
        end

        # @param command_class [Class]
        # @param args [Hash]
        # @return [Manager::Result, Skill::Result, String]
        # @raise [Refused] when the command refuses on stderr
        def call(command_class, **args)
          stdout, stderr, launcher = streams
          bind(launcher, args)
          result = command_class.new(launcher).call(**command_args(args))
          refused!(result, stderr, launcher.exit_code, stdout)
        end

        # @param args [Hash]
        # @return [Identity]
        def identity_for(args)
          build_identity(args) || Identity.current
        end

        private

        attr_reader :backend, :agent_id, :parent_id, :stale_minutes

        # @return [Array(StringIO, StringIO, Launcher)]
        def streams
          stdout = StringIO.new
          stderr = StringIO.new
          [stdout, stderr, Launcher.new([], StringIO.new, stdout, stderr, Kernel, program: "alock")]
        end

        # @param launcher [Launcher]
        # @param args [Hash]
        # @return [void]
        def bind(launcher, args)
          launcher.store_for = backend.method(:store_for)
          launcher.identity = build_identity(args)
          minutes = args.fetch(:stale_minutes, stale_minutes)
          launcher.stale_minutes = minutes unless minutes.nil?
        end

        # @param args [Hash]
        # @return [Hash]
        def command_args(args) = args.except(*SESSION)

        # @param args [Hash]
        # @return [Identity, nil]
        def build_identity(args)
          id = args.fetch(:agent_id, agent_id)
          parent = args.fetch(:parent_id, parent_id)
          return nil if id.nil? && parent.nil?

          env = ENV.to_h
          env["AGENT_ID"] = id unless id.nil?
          env["AGENT_PARENT_ID"] = parent unless parent.nil?
          Identity.new(env: env)
        end

        # @param result [Object]
        # @param stderr [StringIO]
        # @param code [Integer, nil]
        # @param stdout [StringIO]
        # @return [Object]
        # @raise [Refused]
        def refused!(result, stderr, code, stdout)
          text = stderr.string.strip
          raise Refused.new(text, result: result) if text != "" && code.to_i.nonzero?

          result.nil? ? stdout.string.strip : result
        end
      end
    end
  end
end

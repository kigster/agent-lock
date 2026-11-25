# frozen_string_literal: true

require_relative "base"
require_relative "../../skill"

module Agent
  module Lock
    module CLI
      module Commands
        # `alock skills path`: where the bundled skill is, for a harness that
        # would rather link it than copy it, or a configuration that names it
        # by path.
        class SkillsPath < Base
          desc "Print where the bundled agent-lock skill lives"

          # @return [void]
          def call(**)
            say(Skill.source)
          end
        end

        # `alock skills install`: copy the bundled skill into a skills
        # directory, so an agent learns how to claim files before it first
        # needs to.
        class SkillsInstall < Base
          # The skills directory each `--for` agent reads. Anything not named
          # here reads the shared `~/.agents/skills`.
          AGENT_DIRS = { "claude" => ".claude" }.freeze

          desc "Copy the bundled skill (#{Skill.bundled.join(", ")}) into a skills directory"

          option :into, type: :string, default: nil,
                        desc: "Skills directory to install into (default: ~/.agents/skills)"
          option :for, type: :string, default: nil, aliases: ["-a"],
                       desc: "claude installs into ~/.claude/skills, any other agent ~/.agents/skills"
          option :overwrite, type: :boolean, default: false,
                             desc: "Replace an installed copy that differs from the bundled one"

          # An empty example crashes dry-cli-help's renderer, so the default
          # install is spelled out as an option-free line with a comment.
          example [
            " # into ~/.agents/skills",
            "--for claude # into ~/.claude/skills",
            "--into ~/some/skills --overwrite # replace a copy that differs"
          ]

          # @param options [Hash] `:into`, `:for`, `:overwrite`
          # @return [Skill::Result]
          def call(**options)
            into = destination_for(options)
            skill = into ? Skill.new(into: into) : Skill.new

            result = skill.install(overwrite: options[:overwrite])
            report(result)
            finish(result)
          end

          private

          # `--into` wins over `--for`, with a warning, since it is the more
          # specific of the two.
          #
          # @param options [Hash]
          # @return [String, nil] where to install, or nil for Skill's own default
          def destination_for(options)
            return options[:into] unless options[:for]

            if options[:into]
              warn_("Both --for and --into were given; --for is ignored")
              return options[:into]
            end

            File.join(Dir.home, AGENT_DIRS.fetch(options[:for], ".agents"), "skills")
          end

          # @param result [Skill::Result]
          # @return [void]
          def report(result)
            case result.status
            when :installed then say("INSTALLED #{result.path}")
            when :current then say("UP TO DATE #{result.path}")
            when :differs
              warn_("REFUSED: #{result.path} differs from the copy this gem ships")
              warn_("  #{program} skills install --overwrite   # replace it")
            when :linked
              warn_("REFUSED: #{result.path} is a symlink, so something else installs it; left alone")
            end
          end
        end
      end
    end
  end
end

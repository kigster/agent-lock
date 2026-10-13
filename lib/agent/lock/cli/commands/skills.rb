# frozen_string_literal: true

require_relative "base"
require_relative "../../skill"

module Agent
  module Lock
    module CLI
      module Commands
        # Where the bundled skill is, for a harness that would rather link it
        # than copy it, or a configuration that names it by path.
        class SkillsPath < Base
          desc "Print the directory of the skill this gem ships"

          def call(**)
            say(Skill.source)
          end
        end

        # Copy the bundled skill into a skills directory, so an agent learns
        # how to claim files before it first needs to.
        class SkillsInstall < Base
          desc "Copy the skills this gem ships into a skills directory: #{Skill.bundled.join(", ")}"

          option :into, type: :string, default: nil, aliases: ["-o"],
                        desc: "The skills directory, default ~/.agents/skills"
          option :for, type: :string, default: nil, aliases: ["-a"],
                       desc: "AI coding agent name, eg 'codex', or 'claude'"
          option :force, type: :boolean, default: false, aliases: ["-f"],
                         desc: "Replace a copy that differs from this one"

          # An empty example crashes dry-cli-help's renderer, so the default
          # install is spelled out as an option-free line with a comment.
          example [
            " # into ~/.agents/skills",
            "--for claude # into ~/.claude/skills",
            "--into ~/some/skills --force # replace a copy that differs"
          ]

          # @param options [Hash]
          def call(**options)
            into = destination_for(options)
            skill = into ? Skill.new(into: into) : Skill.new

            result = skill.install(force: options[:force])
            report(result)
            finish(result)
          end

          private

          # @param options [Hash]
          # @return [String, nil] where to install, or nil for Skill's own default
          def destination_for(options)
            return options[:into] unless options[:for]

            warn_("Both --for and --into options are provided; --for will be ignored") if options[:into]
            return options[:into] if options[:into]

            agent_dir = options[:for] == "claude" ? ".claude" : ".agents"
            File.join(Dir.home, agent_dir, "skills")
          end

          # @param result [Skill::Result]
          def report(result)
            case result.status
            when :installed then say("INSTALLED #{result.path}")
            when :current then say("UP TO DATE #{result.path}")
            when :differs
              warn_("REFUSED: #{result.path} differs from the copy this gem ships")
              warn_("  #{program} skills install --force   # replace it")
            when :linked
              warn_("REFUSED: #{result.path} is a symlink, so something else installs it; left alone")
            end
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require_relative "base"
require_relative "../../skill"

module Agent
  module Lock
    module CLI
      module Commands
        # Where the bundled skill is, for a harness that would rather link it
        # than copy it, or a configuration that names it by path.
        class SkillPath < Base
          desc "Print the directory of the skill this gem ships"

          def call(**)
            say(Skill.source)
          end
        end

        # Copy the bundled skill into a skills directory, so an agent learns
        # how to claim files before it first needs to.
        class SkillInstall < Base
          desc "Copy the skill this gem ships into a skills directory"

          option :into, type: :string, default: nil,
                        desc: "The skills directory, default ~/.claude/skills"
          option :force, type: :boolean, default: false,
                         desc: "Replace a copy that differs from this one"

          example ["", "--into ~/.agents/skills", "--force"]

          # @param options [Hash]
          def call(**options)
            skill = options[:into] ? Skill.new(into: options[:into]) : Skill.new
            result = skill.install(force: options[:force])
            report(result)
            finish(result)
          end

          private

          # @param result [Skill::Result]
          def report(result)
            case result.status
            when :installed then say("INSTALLED #{result.path}")
            when :current then say("UP TO DATE #{result.path}")
            when :differs
              warn_("REFUSED: #{result.path} differs from the copy this gem ships")
              warn_("  #{program} skill install --force   # replace it")
            when :linked
              warn_("REFUSED: #{result.path} is a symlink, so something else installs it; left alone")
            end
          end
        end
      end
    end
  end
end

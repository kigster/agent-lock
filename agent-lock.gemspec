# frozen_string_literal: true

require_relative "lib/agent/lock/version"

# rubocop: disable-next Layout/LineLength
Gem::Specification.new do |spec|
  spec.name = "agent-lock"
  spec.version = Agent::Lock::VERSION
  spec.authors = ["Konstantin Gredeskoul"]
  spec.email = ["kigster@gmail.com"]

  spec.summary = "Advisory locks to prevent race conditions and general mayhem " \
                 "when multiple AI agents unknowinly modify the same souce three."

  spec.description = "This compact ruby gem is purely CLI utility: it's meant to be used by a team of AI agents" \
                     "executing along one or more the plans in a given repo. Using worktrees and parallelism it's easy to 10x the speed of " \
                     "develpoment of software development compared to even a single agent working on it. Plus each agent can specialize. " \
                     "Such agents require globsl shared locking mechanism to ensure they are not working on the same directory, " \
                     "or the same files in same worktree. That is exactly what this gem does. The CLI binary you invoke is called 'alock'" \
                     "which comes with sub-command 'completion' which you can load for BASH or ZSH. However, you are not very likely going to" \
                     "invoke this gem directly. It's used by an Agentic Workflow gem 'agentilda' to protect shared resources. " \
                     "To try the entire system, it's recommended to download the repo https://github.com/kigster/agentilda-ai-setup " \
                     "which both installs the two gems, and offers a configuration file that installs a set of coding agents, skills, plugins, " \
                     "commands, from various guthub folders, or via running commands, and so on. In other words the repo's purpose is to ensure " \
                     "your agentic setup is identical from machine to machine, and by modifying the config file you can pick and choose your " \
                     "skills, your AGENT.md/CLAUDE.md file and so on."

  spec.homepage = "https://github.com/kigster/agent-lock"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/kigster/agent-lock"
  spec.metadata["changelog_uri"] = "https://github.com/kigster/agent-lock/blob/main/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml .rubocop_todo.yml .plans .envrc
                          justfile/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  spec.add_dependency "dry-cli", "~> 1.4"
  spec.add_dependency "dry-cli-autocomplete", "~> 0.5"
  spec.add_dependency "dry-cli-help", "~> 0.5"
  spec.add_dependency "dry-cli-ui", "~> 0.5"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "redis", "~> 5.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end

# frozen_string_literal: true

require_relative "lib/agent/lock/version"

Gem::Specification.new do |spec|
  spec.name = "agent-lock"
  spec.version = Agent::Lock::VERSION
  spec.authors = ["Konstantin Gredeskoul"]
  spec.email = ["kigster@gmail.com"]

  spec.summary = "Advisory locks for the several coding agents that end up in one checkout"
  spec.description = "A CLI an agent runs before it writes: claim a path or a glob, see who holds one, " \
                     "record progress inside the lock, and pick the work back up after a crash. Identity " \
                     "belongs to the session rather than the process, so a lock taken by one command can be " \
                     "released by the next."
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
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml .plans/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  spec.add_dependency "dry-cli", "~> 1.4"
  spec.add_dependency "dry-cli-autocomplete", "~> 0.1"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "redis", "~> 5.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end

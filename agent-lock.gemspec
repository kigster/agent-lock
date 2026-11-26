# frozen_string_literal: true

require_relative "lib/agent/lock/version"

Gem::Specification.new do |spec|
  spec.name = "agent-lock"
  spec.version = Agent::Lock::VERSION
  spec.authors = ["Konstantin Gredeskoul"]
  spec.email = ["kigster@gmail.com"]

  spec.summary = "Advisory file and directory locks for AI coding agents sharing a checkout or a branch."

  spec.description = "agent-lock installs `alock`, a CLI that coding agents (Claude Code, Codex, Cursor, " \
                     "sub-agents of one session, or agents on several machines) can run before they write: " \
                     "`alock acquire <glob> <intent>` claims a path, and any overlapping claim is refused " \
                     "with who holds it, since when, and why. Locks are Markdown documents kept in Redis " \
                     "(shared across machines) or in a file store inside .git, keyed by repository and " \
                     "branch. Identity comes from the agent session, crashed holders are reaped or " \
                     "orphaned with their notes, and macOS can freeze files outright with --enforce. " \
                     "Used by OpenLanes to keep concurrent agents from overwriting each other. Finally, " \
                     "since version 4.0, all CLI commands are available as Ruby API with some additional " \
                     "benefits such as block usage of acquire(), ability to use multiple lockers, and " \
                     "use the distributed backend in async mode using concurrent_ruby's Async module."

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
                          justfile .yardopts sig/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "concurrent-ruby", "~> 1.3.8"
  spec.add_dependency "dry-cli", "~> 1.4"
  spec.add_dependency "dry-cli-autocomplete", "~> 0.6"
  spec.add_dependency "dry-cli-help", "~> 0.6"
  spec.add_dependency "dry-cli-ui", "~> 0.7"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "redis", "~> 5.0"
end

# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in agent-lock.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "rspec-its"
gem "simplecov"
gem "coverage-badge"
gem "rubocop", "~> 1.21"

# End-to-end specs run the CLI in this process rather than forking one, which
# is what the Launcher's injected streams are for.
gem "aruba", "~> 2.3"

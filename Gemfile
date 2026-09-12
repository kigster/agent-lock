# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in agent-lock.gemspec
gemspec

gem "coverage-badge"
gem "irb"
gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "rspec-its"
gem "rubocop", "~> 1.21"
gem "rubocop-rake"
gem "rubocop-rspec"
gem "simplecov"

# End-to-end specs run the CLI in this process rather than forking one, which
# is what the Launcher's injected streams are for.
gem "aruba", "~> 2.3"

# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in agent-lock.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "rspec-its"

gem "rubocop", "~> 1.21"

# End-to-end specs run the CLI in this process rather than forking one, which
# is what the Launcher's injected streams are for.
gem "aruba", "~> 2.3"

# Only for the optional Redis store. Never a dependency of the gem itself: the
# file store is the default, and nobody should install a client for a backend
# they did not ask for.
gem "redis", "~> 5.0"

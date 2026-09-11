# frozen_string_literal: true

require "fileutils"
require "simplecov"
require "coverage/badge"

# The badge belongs to the repository, not to the gem whose suite produces it,
# and the suite runs from workflow/. Anchoring on __dir__ rather than on the
# working directory keeps it landing in the one docs/badges the README reads.
#
# The directory is made up front because the move happens in `at_exit`, and
# without it the whole suite dies there — which reports as a passing run
# followed by a stack trace.
REPO_ROOT = File.expand_path("../..", __dir__)
BADGE_DIR = File.join(REPO_ROOT, "docs", "badges")
FileUtils.mkdir_p(BADGE_DIR)

SimpleCov.start do
  # `cover` (replacing the deprecated `track_files`) is what makes the number
  # mean anything: without it SimpleCov only counts files some example happened
  # to load, so a library nobody requires reports 100% of nothing. With it, an
  # untested file counts as 0% AND the report is restricted to this pattern —
  # which is also why `spec/` and `bin/` need no separate exclusion below.
  cover "lib/**/*.rb"

  enable_coverage :branch

  self.formatters = [
    SimpleCov::Formatter::HTMLFormatter,
    Coverage::Badge::Formatter
  ]
end

SimpleCov.at_exit do
  SimpleCov.result.format!
  # rubocop: disable-next RSpec/Output
  puts "Coverage: #{SimpleCov.result.covered_percent.round(2)}%"
  FileUtils.mv("coverage/badge.svg", File.join(BADGE_DIR, "coverage_badge.svg"))
end

require "tmpdir"

require "agent/lock"
require "open3"
require "rbconfig"
require "rspec/its"

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |file| require file }

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.include_context "a checkout", type: :checkout

  # The default backend picks Redis when one answers locally, so a developer
  # running this suite with Redis up would otherwise have every example that
  # does not care about backend choice write real locks into their own
  # database, under whatever tree digest a throwaway checkout happens to
  # hash to, with nothing here to ever clean them up. Pinning a backend here
  # keeps the suite deterministic regardless of the machine it runs on;
  # examples about backend selection itself override this with their own
  # AGENT_LOCK_BACKEND, and examples about one backend's own on-disk shape
  # pin themselves to it regardless of this setting.
  #
  # AGENT_LOCK_TEST_BACKEND runs the whole suite against the other backend
  # instead: `AGENT_LOCK_TEST_BACKEND=redis bundle exec rspec`, which is how
  # CI proves the business logic in Manager and the CLI, not just each
  # store's own contract spec, holds up against Redis too. Pinned to
  # RedisHelpers::TEST_REDIS_URL rather than deferring to whatever REDIS_URL
  # happens to be set in the shell this runs in, since this suite gets to
  # decide what it flushes and nothing else does.
  config.around do |example|
    backend = ENV.fetch("AGENT_LOCK_TEST_BACKEND", "file")
    overrides = { "AGENT_LOCK_BACKEND" => backend }
    overrides["REDIS_URL"] = RedisHelpers::TEST_REDIS_URL if backend == "redis"

    with_env(overrides) { example.run }
  end

  config.before do
    next unless ENV["AGENT_LOCK_BACKEND"] == "redis"

    skip "AGENT_LOCK_TEST_BACKEND=redis, but no Redis answers on #{RedisHelpers::TEST_REDIS_URL}" \
      unless redis_reachable?(RedisHelpers::TEST_REDIS_URL)
  end
end

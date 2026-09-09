# frozen_string_literal: true

# kept deliberate: this gem loads what it needs, in order

require_relative "lock/version"

module Agent
  # Advisory locks for the several coding agents that end up in one checkout.
  #
  # `Agent::Lock` is the library; `agent-lock` is the executable. Everything
  # the CLI does is a method on Manager, which prints nothing and exits
  # nothing, so the whole lifecycle is testable without capturing output.
  module Lock
    class Error < StandardError; end
  end
end

require_relative "lock/process_info"
require_relative "lock/identity"
require_relative "lock/tree"
require_relative "lock/scope"
require_relative "lock/record"
require_relative "lock/freeze"
require_relative "lock/store"
require_relative "lock/store/file_system"
require_relative "lock/store/redis"
require_relative "lock/manager"
require_relative "lock/launcher"
require_relative "lock/cli"

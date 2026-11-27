# frozen_string_literal: true

require_relative "../identity"
require_relative "../manager"
require_relative "../tree"

module Agent
  module Lock
    class Facade
      # Who is asking, against which store: a {Manager} per call.
      #
      # Holds the facade's defaults and nothing that changes, and builds a
      # fresh {Manager}, {Tree} and store for every call. Two threads never
      # share one of those, which is what keeps a facade thread-safe without
      # a lock of its own; the store's own mutex serializes the writes.
      class Session
        # What a lock's holder may be tied to, for liveness: see {#initialize}.
        HOLDERS = %i[process session].freeze

        # @param backend [Backend]
        # @param agent_id [String, nil] the holder name when a call does not pass one
        # @param parent_id [String, nil] the parent when a call does not pass one
        # @param stale_minutes [Integer, nil] nil reads `AGENT_LOCK_STALE_MINUTES`
        # @param holder [Symbol] `:process` ties a lock to this Ruby process,
        #   so a host that crashes is reaped like a dead `alock` session;
        #   `:session` ties it to the first non-shell ancestor, as `alock`
        #   does, for a short script whose lock should outlive it
        # @raise [ArgumentError] for any other holder
        def initialize(backend, agent_id: nil, parent_id: nil, stale_minutes: nil, holder: :process)
          unless HOLDERS.include?(holder)
            raise ArgumentError, "holder must be one of #{HOLDERS.join(", ")}, got #{holder.inspect}"
          end

          @backend = backend
          @agent_id = agent_id
          @parent_id = parent_id
          @stale_minutes = stale_minutes
          @holder = holder
          freeze
        end

        # @param dir [String, nil] a directory inside the checkout; nil is the current one
        # @param agent_id [String, nil] overrides the session's default
        # @param parent_id [String, nil] overrides the session's default
        # @param stale_minutes [Integer, nil] overrides the session's default
        # @return [Manager] bound to that checkout, this backend and that identity
        def manager(dir: nil, agent_id: nil, parent_id: nil, stale_minutes: nil)
          tree = Tree.for(dir || ".")
          Manager.new(tree: tree, store: @backend.store_for(tree),
                      identity: identity(agent_id:, parent_id:),
                      stale_minutes: stale_minutes || @stale_minutes)
        end

        # Read fresh from the environment on every call, so it follows
        # `AGENT_ID` as that changes; a name from the call or the session
        # overrides it, and the rest of the environment is kept so the
        # session id and fingerprint still resolve. The pid is read per call
        # too, so a forked child holds its own locks, not its parent's.
        #
        # @param agent_id [String, nil]
        # @param parent_id [String, nil]
        # @return [Identity]
        def identity(agent_id: nil, parent_id: nil)
          id = agent_id || @agent_id
          parent = parent_id || @parent_id
          env = ENV.to_h
          env["AGENT_ID"] = id unless id.nil?
          env["AGENT_PARENT_ID"] = parent unless parent.nil?
          Identity.new(env: env, pid: @holder == :process ? ::Process.pid : nil)
        end
      end
    end
  end
end

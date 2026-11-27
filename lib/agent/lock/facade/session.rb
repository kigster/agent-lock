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
        # What a session's name may be made of: see {.name!}.
        NAME = %r{\A[A-Za-z0-9._:@/+-]+\z}

        # @param backend [Backend]
        # @param agent_id [String, nil] the holder name when a call does not pass one
        # @param parent_id [String, false, nil] the parent when a call does
        #   not pass one; `false` says there is none, where nil infers it
        # @param stale_minutes [Integer, nil] nil reads `AGENT_LOCK_STALE_MINUTES`
        # @param holder [Symbol, nil] `:process`, the default, ties a lock to this Ruby process,
        #   so a host that crashes is reaped like a dead `alock` session;
        #   `:session` ties it to the first non-shell ancestor, as `alock`
        #   does, for a short script whose lock should outlive it
        # @param session_name [String, nil] the session's name, in place of
        #   `CLAUDE_SESSION_ID` and the fingerprint: a plan id, a job id.
        #   Its locks are tied to no process, so they survive any restart of
        #   the host and lapse only when untouched for `stale_minutes`
        # @raise [ArgumentError] for any other holder, for `holder:` given
        #   beside `session_name:`, which ties a lock to no process at all,
        #   and for a name that is not one
        # rubocop:disable-next Metrics/ParameterLists
        def initialize(backend, agent_id: nil, parent_id: nil, stale_minutes: nil, holder: nil, session_name: nil)
          @holder = Session.holder!(holder, named: !session_name.nil?)
          @backend = backend
          @agent_id = agent_id
          @parent_id = Session.parent!(parent_id)
          @stale_minutes = stale_minutes
          @session_name = Session.name!(session_name)
          freeze
        end

        class << self
          # @param holder [Symbol, nil] nil is `:process`
          # @param named [Boolean] whether the facade names its session
          # @return [Symbol]
          # @raise [ArgumentError]
          def holder!(holder, named:)
            if holder && named
              raise ArgumentError, "holder: does not go with session_name:, which ties a lock to no process"
            end
            return holder || :process if holder.nil? || HOLDERS.include?(holder)

            raise ArgumentError, "holder must be one of #{HOLDERS.join(", ")}, got #{holder.inspect}"
          end

          # `true` is refused, not read as some parent: it names nobody.
          #
          # @param parent [String, false, nil]
          # @return [String, false, nil]
          # @raise [ArgumentError] for anything else
          def parent!(parent)
            return parent if parent.nil? || parent == false || parent.is_a?(String)

            raise ArgumentError, "parent_id must be a String, or false for none, got #{parent.inspect}"
          end

          # A holder id is pasted back into a shell, so it holds nothing a
          # shell would read as more than a word.
          #
          # @param name [String, nil]
          # @return [String, nil]
          # @raise [ArgumentError] for a name that is not {NAME}
          def name!(name)
            return name if name.nil? || (name.is_a?(String) && name.match?(NAME))

            raise ArgumentError, "session_name must be letters, digits and any of . _ : @ / + -, got #{name.inspect}"
          end
        end

        # @param dir [String, nil] a directory inside the checkout; nil is the current one
        # @param agent_id [String, nil] overrides the session's default
        # @param parent_id [String, nil] overrides the session's default
        # @param stale_minutes [Integer, nil] overrides the session's default
        # @param session_name [String, nil] overrides the session's default
        # @return [Manager] bound to that checkout, this backend and that identity
        def manager(dir: nil, agent_id: nil, parent_id: nil, stale_minutes: nil, session_name: nil)
          tree = Tree.for(dir || ".")
          Manager.new(tree: tree, store: @backend.store_for(tree),
                      identity: identity(agent_id:, parent_id:, session_name:),
                      stale_minutes: stale_minutes || @stale_minutes)
        end

        # Read fresh from the environment on every call, so it follows
        # `AGENT_ID` as that changes; a name from the call or the session
        # overrides it, and the rest of the environment is kept so the
        # session id and fingerprint still resolve. The pid is read per call
        # too, so a forked child holds its own locks, not its parent's.
        #
        # A named session is tied to no process; `holder:` is for a facade
        # that names none.
        #
        # @param agent_id [String, nil]
        # @param parent_id [String, false, nil] `false` for a holder with no
        #   parent; nil uses the session's default, and without one infers it
        # @param session_name [String, nil] overrides the session's default
        # @return [Identity]
        # @raise [ArgumentError] for a name or a parent that is not one
        def identity(agent_id: nil, parent_id: nil, session_name: nil)
          name = Session.name!(session_name) || @session_name
          liveness = ::Process.pid if @holder == :process && name.nil?
          parent = Session.parent!(parent_id).nil? ? @parent_id : parent_id
          Identity.new(env: env_for(agent_id || @agent_id, parent),
                       liveness_pid: liveness, session_name: name)
        end

        private

        # @param id [String, nil]
        # @param parent [String, false, nil]
        # @return [Hash{String => String}] the environment, with those two
        #   named. No parent is AGENT_PARENT_ID set and empty, as on the CLI
        def env_for(id, parent)
          env = ENV.to_h
          env["AGENT_ID"] = id unless id.nil?
          env["AGENT_PARENT_ID"] = parent || "" unless parent.nil?
          env
        end
      end
    end
  end
end

# frozen_string_literal: true

require_relative "base"
require_relative "../../identity"

module Agent
  module Lock
    module CLI
      module Commands
        # Who a lock taken from here would say holds it, and who its parent is.
        #
        # A sub-agent runs inside its parent's process, so nothing but the
        # AGENT_ID it was told to use tells the two apart. A typo or a missing
        # export puts its locks down under somebody else's name, where they
        # block no sibling, and nothing says so. This is the check to run
        # before the first claim: `AGENT_ID=rey-frontend alo whoami`.
        #
        # It reads the environment and nothing else. No tree and no store, so
        # asking the question can neither fail outside a checkout nor leave a
        # store behind in one.
        class Whoami < Base
          # Where #id came from, worded for a human. The keys are Identity's
          # own symbols, which are what --json reports.
          SOURCES = {
            explicit: "from AGENT_ID",
            session: "from CLAUDE_SESSION_ID",
            fingerprint: "from the process fingerprint"
          }.freeze

          # Where #parent_id came from, likewise.
          PARENT_SOURCES = {
            explicit: "from AGENT_PARENT_ID",
            inferred: "inferred: the session this runs in, since AGENT_ID names somebody else"
          }.freeze

          desc "Say who a lock taken now would be held by, and where that came from"

          option :json, type: :boolean, default: false, desc: "Machine-readable output"

          example ["", "--json"]

          # @param options [Hash]
          def call(**options)
            identity = Identity.current
            warn_shared(identity) unless identity.source == :explicit
            return say(JSON.pretty_generate(as_hash(identity))) if options[:json]

            say("id:     #{identity.id}  (#{SOURCES.fetch(identity.source)})")
            say(parent_line(identity))
          end

          private

          # @param identity [Identity]
          # @return [String]
          def parent_line(identity)
            return "parent: none" if identity.parent_id.nil?

            "parent: #{identity.parent_id}  (#{PARENT_SOURCES.fetch(identity.parent_source)})"
          end

          # The failure this command exists to catch. Without AGENT_ID, every
          # sub-agent of this session inherits the same environment and runs
          # in the same process, so each resolves to this same id and none of
          # them can ever block another.
          #
          # @param identity [Identity]
          def warn_shared(identity)
            warn_("note: every sub-agent of this session answers to #{identity.id} too, so none can block another.")
            warn_("      Give each one its own: AGENT_ID=<name> #{program} acquire ...")
          end

          # @param identity [Identity]
          # @return [Hash]
          def as_hash(identity)
            { id: identity.id, source: identity.source,
              parent_id: identity.parent_id, parent_source: identity.parent_source }
          end
        end
      end
    end
  end
end

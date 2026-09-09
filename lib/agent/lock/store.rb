# frozen_string_literal: true

module Agent
  module Lock
    # Where locks are kept. One tree, one store, chosen on purpose.
    #
    # The backend is never auto-detected. An agent that finds Redis running and
    # switches to it, while the agent beside it does not, gives two sessions two
    # separate stores in which neither can see the other's locks — a lock that
    # is worse than no lock, because it reports success. So the choice comes
    # from AGENT_LOCK_BACKEND, and the first store created in a tree records
    # what it is, so a second process in that tree cannot silently pick the
    # other one.
    module Store
      MARKER = "backend"

      class Mismatch < Error; end

      module_function

      # @param tree [Tree]
      # @return [Store::FileSystem, Store::Redis]
      def for(tree)
        wanted = (ENV["AGENT_LOCK_BACKEND"] || recorded(tree) || "file").downcase
        established = recorded(tree)

        if established && established != wanted
          raise Mismatch, "this tree's locks live in #{established}, not #{wanted} — " \
                          "release them before switching backends"
        end

        build(wanted, tree).tap { |_store| record(tree, wanted) }
      end

      # @return [Store::FileSystem, Store::Redis]
      def build(name, tree)
        case name
        when "file" then FileSystem.new(tree)
        when "redis" then Redis.new(tree)
        else raise Mismatch, "unknown backend #{name.inspect} — expected file or redis"
        end
      end

      # @return [String, nil] the backend this tree already uses
      def recorded(tree)
        path = marker_path(tree)
        File.exist?(path) ? File.read(path).strip : nil
      rescue SystemCallError
        nil
      end

      def record(tree, name)
        path = marker_path(tree)
        return if File.exist?(path)

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{name}\n")
      rescue SystemCallError
        nil
      end

      def marker_path(tree) = File.join(tree.store_dir, MARKER)
    end
  end
end

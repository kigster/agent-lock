# frozen_string_literal: true

require_relative "error"
require_relative "store/file_system_store"
require_relative "store/redis_store"

require "fileutils"

module Agent
  module Lock
    # Where locks are kept. One tree, one store, chosen on purpose.
    #
    # AGENT_LOCK_BACKEND wins when set. Otherwise a tree that already has a
    # marker keeps using it. A virgin tree defaults to Redis when one answers
    # locally, file when none does.
    #
    # That default is still never a runtime auto-*switch*: once a marker
    # exists, every later process in that tree is bound to it regardless of
    # what Redis is doing, because an agent that quietly moved to a different
    # store than the agent beside it would give the two of them two stores in
    # which neither can see the other's locks, a lock that is worse than no
    # lock, because it reports success.
    #
    # The one moment that default is decided is also the one moment two
    # processes could race: both find a virgin tree, both probe Redis, and a
    # flaky answer could hand them different defaults before either writes the
    # marker. So the marker is claimed atomically (first `O_CREAT|O_EXCL` wins)
    # and every process builds from whatever ends up on disk, never from its
    # own guess, so a race can pick either backend but never a split.
    module Store
      MARKER = "backend"

      class Mismatch < Error; end

      module_function

      # @param tree [Tree]
      # @return [Store::FileSystemStore, Store::RedisStore]
      def for(tree)
        requested = ENV["AGENT_LOCK_BACKEND"]&.downcase
        established = recorded(tree)

        if established
          if requested && requested != established
            raise Mismatch, "this tree's locks live in #{established}, not #{requested}, " \
                            "release them before switching backends"
          end

          return build(established, tree)
        end

        build(claim(tree, requested || default_backend), tree)
      end

      # @return [Store::FileSystemStore, Store::RedisStore]
      def build(name, tree)
        case name
        when "redis" then RedisStore.new(tree)
        when "file" then FileSystemStore.new(tree)
        else raise Mismatch, "unknown backend #{name.inspect}, expected file or redis"
        end
      end

      # @return [String, nil] the backend this tree already uses
      def recorded(tree)
        path = marker_path(tree)
        File.exist?(path) ? File.read(path).strip : nil
      rescue SystemCallError
        nil
      end

      # Atomically claims the marker for a virgin tree with `name`, or, when a
      # concurrent process already claimed it first, reads back whatever that
      # process wrote instead. Either way, every caller ends up building the
      # same backend for this tree.
      #
      # @param tree [Tree]
      # @param name [String] this process's proposed backend
      # @return [String] the backend actually recorded, which may not be `name`
      def claim(tree, name)
        path = marker_path(tree)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{name}\n", mode: File::WRONLY | File::CREAT | File::EXCL)
        name
      rescue Errno::EEXIST
        recorded(tree) || name
      rescue SystemCallError
        name
      end

      def marker_path(tree) = File.join(tree.store_dir, MARKER)

      # @return [String] "redis" when one answers on REDIS_URL, "file" otherwise
      def default_backend
        local_redis_available? ? "redis" : "file"
      end

      def local_redis_available?
        client, error = RedisStore.create_client
        !client.nil? && error.nil?
      end
    end
  end
end

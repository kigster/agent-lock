# frozen_string_literal: true

require "fileutils"

module Agent
  module Lock
    module Store
      # Locks as files, which is the default and the one that needs nothing
      # installed. See Tree#store_dir for why they live inside `.git`.
      class FileSystem
        SUFFIX = ".lock.md"

        attr_reader :tree

        def initialize(tree)
          @tree = tree
        end

        # @return [String]
        def dir = tree.store_dir

        # @return [String] how a listing names this store
        def describe = dir

        # @return [Array<Record>] every lock here, other worktrees included
        def all
          Dir.glob(File.join(dir, "*#{SUFFIX}")).sort.filter_map { |path| Record.read(path) }
        end

        # @param scope [Scope]
        # @return [Record, nil]
        def find(scope) = Record.read(path_for(Record.id_for(tree, scope)))

        # Atomic: two agents racing for one scope cannot both win, because only
        # one File::EXCL create succeeds.
        #
        # @param record [Record]
        # @return [Boolean] false when somebody else got there first
        def create(record)
          FileUtils.mkdir_p(dir)
          File.open(path_for(record.id), File::WRONLY | File::CREAT | File::EXCL) do |file|
            file.write(record.to_markdown)
          end
          true
        rescue Errno::EEXIST
          false
        end

        # Replace a lock in place. Written beside itself and renamed, so a
        # reader never sees half a document, and so a crash mid-write leaves
        # the previous version rather than nothing.
        #
        # @param record [Record]
        # @return [void]
        def update(record)
          path = record.path || path_for(record.id)
          temp = "#{path}.#{Process.pid}.tmp"
          File.write(temp, record.to_markdown)
          File.rename(temp, path)
        end

        # @param record [Record]
        # @return [void]
        def delete(record) = FileUtils.rm_f(record.path || path_for(record.id))

        # @param id [String]
        # @return [String]
        def path_for(id) = File.join(dir, "#{id}#{SUFFIX}")
      end
    end
  end
end

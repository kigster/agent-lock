# frozen_string_literal: true

require_relative "../error"
require_relative "../record"

require "fileutils"

module Agent
  module Lock
    module Store
      # Locks as files, which is the default and the one that needs nothing
      # installed. See Tree#store_dir for why they live inside `.git`.
      class FileSystem
        SUFFIX = ".lock.md"
        MUTEX = ".mutex"

        # Seconds. A claim's critical section is a directory scan and one
        # write, so anything near this is somebody stuck, not somebody busy.
        MUTEX_TIMEOUT = 15

        attr_reader :tree

        def initialize(tree)
          @tree = tree
        end

        # @return [String]
        def dir = tree.store_dir

        # @return [String] how a listing names this store
        def describe = dir

        # FNM_DOTMATCH is load-bearing. A scope like `.plans/**` slugs to a
        # filename that starts with a dot, and a plain glob skips it, so the
        # lock was written, listed nowhere, and blocked nobody. Redis matches
        # those keys either way, and a store that enumerates less than it holds
        # is worse than no store at all.
        #
        # @return [Array<Record>] every lock here, other worktrees included
        def all
          Dir.glob(File.join(dir, "*#{SUFFIX}"), File::FNM_DOTMATCH)
             .sort
             .filter_map { |path| Record.read(path) }
        end

        # Runs the block with every other process in this store shut out, so a
        # scan for conflicts and the write it justifies cannot be interleaved.
        # O_EXCL alone settles a race for one scope, but `lib/**` and
        # `lib/a1.rb` are two files, and two agents that both scanned an empty
        # store before either wrote both won.
        #
        # An exclusive flock on `.mutex` beside the locks. The kernel drops it
        # when the holder exits, crash included, so a dead agent cannot leave
        # the store wedged. A live one that stops mid-claim can, which is why
        # the wait is bounded and ends in an error rather than a hung agent.
        #
        # Not re-entrant. flock belongs to an open file, not to a process, so
        # a nested call opens a second one, waits on the first, and raises
        # once the timeout runs out.
        #
        # @yield the critical section
        # @return [Object] whatever the block returns
        # @raise [Error] when the mutex stayed held for longer than the timeout
        def synchronize
          FileUtils.mkdir_p(dir)
          # Closing the file releases the flock, and the block form closes it
          # on the way out whether the critical section returned or raised.
          File.open(mutex_path, File::RDWR | File::CREAT, 0o644) do |file|
            wait_for(file)
            yield
          end
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

        # Named so that `all`'s `*.lock.md` can never match it, dot or no dot.
        #
        # @return [String]
        def mutex_path = File.join(dir, MUTEX)

        private

        # Polls with a non-blocking flock rather than blocking on it, because
        # a blocking flock cannot be given up on: an agent stuck behind a
        # stopped `alo` would wait forever with nothing on its screen.
        #
        # @param file [File] the open mutex
        # @return [void]
        # @raise [Error] once the timeout has passed
        def wait_for(file)
          timeout = mutex_timeout
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          delay = 0.005
          until file.flock(File::LOCK_EX | File::LOCK_NB)
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              raise Error, format("timed out after %<timeout>gs waiting for %<path>s, " \
                                  "which another process claiming a lock is holding", timeout:, path: mutex_path)
            end

            # Jittered, so that processes which all lost the same round do not
            # all come back for the next one at the same instant.
            sleep(delay * rand(0.5..1.0))
            delay = [delay * 2, 0.1].min
          end
        end

        # @return [Float] seconds to wait for the mutex before giving up
        def mutex_timeout = Float(ENV.fetch("AGENT_LOCK_MUTEX_TIMEOUT", MUTEX_TIMEOUT))
      end
    end
  end
end

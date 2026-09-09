# frozen_string_literal: true

module Agent
  module Lock
    # The three questions this gem asks the operating system about a process:
    # what it is called, who its parent is, and when it started.
    #
    # `ps` rather than /proc, because this has to work the same on macOS and on
    # Linux, and because none of it is on a hot path. Every answer is nil when
    # the process is gone, which callers read as "no longer running".
    module ProcessInfo
      module_function

      # @param pid [Integer]
      # @return [String, nil] the executable's name, without its path
      def command(pid)
        value = ps(pid, "comm")
        value && File.basename(value)
      end

      # @param pid [Integer]
      # @return [Integer, nil]
      def parent_of(pid)
        value = ps(pid, "ppid")
        value && Integer(value, exception: false)
      end

      # The wall-clock start time, which is what tells a live process from a
      # different one that inherited its recycled pid.
      #
      # @param pid [Integer]
      # @return [String, nil]
      def started_at(pid) = ps(pid, "lstart")

      # @param pid [Integer, nil]
      # @param started [String, nil] as recorded when the lock was taken
      # @return [Boolean] whether that exact process is still running
      def alive?(pid, started: nil)
        return false if pid.nil?

        now = started_at(pid)
        return false if now.nil?
        return true if started.nil? || started.empty?

        now == started
      end

      # @return [String, nil] the field, or nil for a process that is gone
      def ps(pid, field)
        return nil if pid.nil?

        out = IO.popen(["ps", "-p", pid.to_s, "-o", "#{field}="], err: File::NULL, &:read)
        out = out.to_s.strip
        out.empty? ? nil : out
      rescue SystemCallError
        nil
      end
    end
  end
end

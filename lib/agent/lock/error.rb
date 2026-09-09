# frozen_string_literal: true

module Agent
  module Lock
    # The base of everything this gem raises. In a file of its own so that any
    # part of the library can require it without reaching for the entry point,
    # which would require the part doing the asking.
    class Error < StandardError; end
  end
end

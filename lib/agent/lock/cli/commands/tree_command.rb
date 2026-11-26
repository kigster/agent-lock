# frozen_string_literal: true

require_relative "base"

module Agent
  module Lock
    module CLI
      module Commands
        # A command that works on the lock store of one checkout, and so
        # takes `--dir` to name which checkout that is.
        #
        # `--dir` is added in `inherited` rather than restated in every
        # subclass, so a new lock verb gets it by subclassing and cannot
        # forget it.
        #
        # @abstract Subclass and implement `#call(**options)`.
        class TreeCommand < Base
          # @param subclass [Class<TreeCommand>]
          # @return [void]
          def self.inherited(subclass)
            super
            subclass.option :dir, type: :string, default: ".",
                                  desc: "Act on the checkout that contains this directory"
          end
        end
      end
    end
  end
end

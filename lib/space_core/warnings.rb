# frozen_string_literal: true

module Space::Core
  module Warnings
    module_function

    def disable_experimental!
      return unless Warning.respond_to?(:[]) && Warning.respond_to?(:[]=)

      Warning[:experimental] = false
    end
  end
end

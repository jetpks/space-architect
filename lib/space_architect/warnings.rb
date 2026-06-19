# frozen_string_literal: true

module SpaceArchitect
  module Warnings
    module_function

    def without_experimental
      return yield unless Warning.respond_to?(:[]) && Warning.respond_to?(:[]=)

      original = Warning[:experimental]
      Warning[:experimental] = false
      yield
    ensure
      Warning[:experimental] = original unless original.nil?
    end
  end
end

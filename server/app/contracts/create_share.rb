# auto_register: false
# frozen_string_literal: true

require "dry/validation"

module Space
  module Server
    module Contracts
      class CreateShare < Dry::Validation::Contract
        params do
          required(:share).hash do
            required(:login).filled(:string)
            optional(:access).maybe(:string)
          end
        end
      end
    end
  end
end

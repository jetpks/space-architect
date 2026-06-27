# auto_register: false
# frozen_string_literal: true

require "dry/validation"

module Architect
  module Contracts
    class UpdateShare < Dry::Validation::Contract
      params do
        required(:share).hash do
          required(:access).filled(:string)
        end
      end
    end
  end
end

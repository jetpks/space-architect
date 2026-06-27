# auto_register: false
# frozen_string_literal: true

require "dry/validation"

module Architect
  module Contracts
    class CreateConversation < Dry::Validation::Contract
      params do
        required(:conversation).hash do
          required(:source_file).filled
        end
      end
    end
  end
end

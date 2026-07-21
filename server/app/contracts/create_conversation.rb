# auto_register: false
# frozen_string_literal: true

require "dry/validation"

module Space
  module Server
    module Contracts
      class CreateConversation < Dry::Validation::Contract
        params do
          required(:conversation).hash do
            required(:source_file).filled
            optional(:session_id).filled(:string)
          end
        end
      end
    end
  end
end

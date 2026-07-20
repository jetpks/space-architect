# auto_register: false
# frozen_string_literal: true

require "dry/validation"
require_relative "shared/harness_environment"

module Space
  module Server
    module Contracts
      # A provider is a simple user-owned row (BRIEF §1.6) — unlike CreateProfile,
      # its wire shape is FLAT (no spec: wrapper). base_url/api_key_ref reuse the
      # shared HarnessEnvironment vocabulary's format constants directly (not
      # `include Shared::HarnessEnvironment` — that hook wires environment.env/
      # files rules this contract has no fields for) so the http(s)/op:// failure
      # messages stay byte-identical to CreateJob/CreateProfile's.
      class CreateProvider < Dry::Validation::Contract
        FLAVORS = %w[openai anthropic].freeze

        HTTP_URI_FORMAT = Shared::HarnessEnvironment::HTTP_URI_FORMAT
        OP_REF_FORMAT    = Shared::HarnessEnvironment::OP_REF_FORMAT

        params do
          required(:name).filled(:string)
          required(:base_url).filled(:string, format?: HTTP_URI_FORMAT)
          optional(:api_key_ref).maybe(:string, format?: OP_REF_FORMAT)
          required(:flavors).filled(:array).each(:str?, included_in?: FLAVORS)
        end

        rule(:flavors) do
          key.failure("must not contain duplicates") if value.is_a?(::Array) && value.uniq.length != value.length
        end
      end
    end
  end
end

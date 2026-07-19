# auto_register: false
# frozen_string_literal: true

require "dry/validation"

module Space
  module Server
    module Contracts
      class CreateJob < Dry::Validation::Contract
        HARNESS_TYPES    = %w[claude].freeze
        HTTP_URI_FORMAT  = URI::DEFAULT_PARSER.make_regexp(%w[http https]).freeze
        OP_REF_FORMAT    = /\Aop:\/\//.freeze
        ENV_NAME_FORMAT  = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze

        # A secret VALUE can never enter the spec — only an op:// reference. Unknown
        # keys are dropped (house convention, e.g. create_conversation_test.rb).
        SECRET_REF_TYPE = Types::Hash.schema(
          ref:  Types::String.constrained(format: OP_REF_FORMAT),
          name: Types::String.constrained(filled: true, format: ENV_NAME_FORMAT)
        )

        params do
          required(:harness).hash do
            required(:type).filled(:string, included_in?: HARNESS_TYPES)
            required(:model).filled(:string)
            required(:backend).hash do
              required(:base_url).filled(:string, format?: HTTP_URI_FORMAT)
              optional(:api_key_ref).maybe(:string, format?: OP_REF_FORMAT)
            end
            optional(:args).array(:string)
          end
          required(:prompt).filled(:string)
          required(:environment).hash do
            optional(:env).value(Types::Hash.default({}.freeze))
            optional(:secrets).value(Types::Array.of(SECRET_REF_TYPE).default([].freeze))
            optional(:deps).value(Types::Array.of(Types::String.constrained(filled: true)).default([].freeze))
            optional(:files).maybe(:string, :filled?)
            optional(:permissions).hash do
              optional(:network).value(Types::Params::Bool.default(false))
              optional(:mounts).value(Types::Array.of(Types::String).default([].freeze))
            end
          end
        end

        # environment.env values become shell env vars, so every value must be a
        # string (JSON lets a caller send a number/bool/null/object). Keys arrive
        # pre-symbolized by Hanami::Router::Params.deep_symbolize regardless of
        # transport (form-encoded or JSON), so only values are checked here; dry-schema
        # has no Hash[String, String] map type for params (Types::Hash.map raises
        # NotImplementedError inside dry-schema's params DSL — Map types aren't
        # supported there), hence the plain rule instead of a tighter schema type.
        rule(environment: :env) do
          value.each do |k, v|
            key([:environment, :env, k]).failure("must be a string") unless v.is_a?(String)
          end
        end
      end
    end
  end
end

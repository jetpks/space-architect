# frozen_string_literal: true

require "dry/validation"
require "dry/validation/extensions/monads"
require "dry/monads"

module Space::Src
  module Config
    # Validates the raw YAML hash before it is built into a Config struct.
    # Returns a Dry::Monads::Result (via the :monads extension):
    #   Success(validated_hash)  — keys are coerced + bad keys dropped
    #   Failure(errors_to_h)     — field-level messages keyed by path
    #
    # Per gate G2, each rejection case (missing required field, bad
    # refresh_interval, non-integer concurrency, malformed repo entry,
    # malformed org entry) must produce a Failure with a field-level
    # message — verified by Config::ContractTest.
    class Contract < Dry::Validation::Contract
      include Dry::Monads[:result]

      schema do
        optional(:base_dir).filled(:string)
        optional(:refresh_interval).filled(:integer, gt?: 0)
        optional(:concurrency).filled(:integer, gt?: 0)

        optional(:repos).array(:hash) do
          optional(:host).filled(:string)
          required(:owner).filled(:string)
          required(:name).filled(:string)
        end

        optional(:orgs).array(:hash) do
          optional(:host).filled(:string)
          required(:name).filled(:string)
          optional(:include_archived).filled(:bool)
          optional(:include_forks).filled(:bool)
          optional(:ignored_repos).array(:string)
        end
      end

      # Override call to return a Dry::Monads::Result. Dry-validation's
      # monads extension gives us Result#to_monad; we map to our own
      # namespace so callers see a single Result type at every boundary.
      def call(input)
        result = super
        if result.success?
          Success(result.to_h)
        else
          Failure(result.errors.to_h)
        end
      end
    end
  end
end

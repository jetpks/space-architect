# auto_register: false
# frozen_string_literal: true

require "dry/validation"
require_relative "shared/harness_environment"

module Space
  module Server
    module Contracts
      # A profile is a stored PARTIAL job spec — the harness + environment
      # fragments of Contracts::CreateJob's vocabulary, minus prompt/workspace/
      # provenance — plus a user-chosen name. Secret hygiene: profiles store
      # config, never credentials. Secret values can never enter a profile's
      # spec — only op:// references (harness.backend.api_key_ref,
      # environment.secrets[].ref), enforced by the shared HarnessEnvironment
      # vocabulary below. environment.files[].content_b64 is operator-vetted
      # config text, not a place to smuggle credentials.
      class CreateProfile < Dry::Validation::Contract
        # The shipped frontend (Profiles/New.tsx) wraps the harness/environment
        # fragments under a spec key, so the shared vocabulary's env/files rules
        # must run against spec-prefixed paths — see harness_environment.rb.
        def self.environment_rule_prefix = [:spec]

        include Shared::HarnessEnvironment

        params do
          required(:name).filled(:string)
          required(:spec).hash do
            required(:harness).hash(&Shared::HarnessEnvironment::HARNESS_SCHEMA)
            required(:environment).hash(&Shared::HarnessEnvironment::ENVIRONMENT_SCHEMA)
          end
        end
      end
    end
  end
end

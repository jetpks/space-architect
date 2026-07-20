# auto_register: false
# frozen_string_literal: true

require "dry/validation"
require_relative "shared/harness_environment"

module Space
  module Server
    module Contracts
      class CreateJob < Dry::Validation::Contract
        include Shared::HarnessEnvironment

        HARNESS_TYPES = Shared::HarnessEnvironment::HARNESS_TYPES

        params do
          required(:harness).hash(&Shared::HarnessEnvironment::HARNESS_SCHEMA)
          required(:prompt).filled(:string)
          required(:environment).hash(&Shared::HarnessEnvironment::ENVIRONMENT_SCHEMA)
          optional(:workspace).hash do
            required(:dir).filled(:string)
          end
          optional(:provenance).hash do
            required(:space).filled(:string)
            required(:iteration).filled(:string)
            required(:lane).filled(:string)
          end
        end

        # workspace.dir shares mounts' absolute/non-escaping posture
        # (SandboxArgv.valid_mount?) — rejected at submission rather than left to
        # fail at execution.
        rule(workspace: :dir) do
          key.failure("must be an absolute path") if key? && !absolute_path?(value)
        end
      end
    end
  end
end

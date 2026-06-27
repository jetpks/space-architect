# auto_register: false
# frozen_string_literal: true

require "dry/validation"

module Space
  module Server
    module Contracts
      class CreateAnnotation < Dry::Validation::Contract
        params do
          required(:annotation).hash do
            optional(:body).maybe(:string)
            optional(:target_kind).maybe(:string)
            optional(:anchor_message_id).maybe(:integer)
            optional(:tool_use_id).maybe(:string)
            optional(:selector).maybe(:hash)
          end
        end

        rule(annotation: :tool_use_id) do
          next unless value.is_a?(String) && !value.empty?
          next if values.dig(:annotation, :target_kind) == "tool"

          key.failure("is only valid for tool targets")
        end

        rule(annotation: :selector) do
          next unless value.is_a?(Hash)

          unless values.dig(:annotation, :target_kind) == "message"
            key.failure("is only valid for message targets")
            next
          end

          sel = value.transform_keys(&:to_s)
          key.failure("must quote the selected text") if sel["exact"].to_s.empty?
          key.failure("has unknown keys") unless (sel.keys - %w[exact prefix suffix position]).empty?
        end
      end
    end
  end
end

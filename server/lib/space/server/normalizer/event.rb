# frozen_string_literal: true

module Space
  module Server
    module Normalizer
      # Stop-reason and block-type normalization maps, plus the frozen-hash event factory.
      module Event
        STOP_REASONS = {
          "end_turn"      => :end_turn,
          "stop"          => :end_turn,
          "tool_use"      => :tool_use,
          "tool-calls"    => :tool_use,
          "toolUse"       => :tool_use,
          "max_tokens"    => :max_tokens,
          "stop_sequence" => :stop_sequence
        }.freeze

        BLOCK_TYPES = {
          "text"     => :text,
          "tool_use" => :tool_use,
          "toolCall" => :tool_use,
          "thinking" => :thinking
        }.freeze

        def self.normalize_stop_reason(raw)
          return nil if raw.nil?
          STOP_REASONS.fetch(raw) { raw.to_sym }
        end

        def self.make(type, **attrs)
          { type: type, **attrs }.freeze
        end
      end
    end
  end
end

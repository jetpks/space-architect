# frozen_string_literal: true

module Architect
  module Transcript
    # The addressable things inside a conversation: the conversation itself, and
    # the derived hierarchy hanging off messages — turns, prompts, rounds, tool
    # calls, and the messages themselves. None of these need rows of their own;
    # every one reduces to a kind plus an anchor message (and a tool_use id for
    # tool calls), so an Entity is a parsed/validated address, not a record.
    #
    # The canonical address doubles as the URL fragment and the entities API path
    # segment, and matches the DOM ids the client already renders:
    #
    #   conversation | turn-<id> | prompt-<id> | round-<id> | message-<id>
    #   tool-<id>    (an optional -<tool_use_id> suffix disambiguates a message
    #                 with several tool_use blocks; normally there's exactly one)
    class Entity
      KINDS = %w[conversation turn prompt round tool message].freeze

      ADDRESS = /\A(turn|prompt|round|tool|message)-(\d+)(?:-([\w-]+))?\z/

      attr_reader :kind, :message, :tool_use_id, :turn

      # An address string into target-descriptor attributes, or nil for garbage.
      # Purely syntactic — use .locate to check the target actually exists.
      def self.parse(address)
        return { target_kind: "conversation", anchor_message_id: nil, tool_use_id: nil } if address == "conversation"

        match = ADDRESS.match(address.to_s)
        return nil unless match
        return nil if match[3] && match[1] != "tool"

        { target_kind: match[1], anchor_message_id: match[2].to_i, tool_use_id: match[3] }
      end

      # The short canonical form — tool addresses omit the tool_use_id suffix to
      # match the client's tool-<message_id> DOM anchors.
      def self.address_for(kind, message_id)
        kind.to_s == "conversation" ? "conversation" : "#{kind}-#{message_id}"
      end

      # Resolve target attributes against a set of derived turns, returning an Entity
      # (with its owning turn) or nil when the target is incoherent — an anchor
      # outside the conversation, a mid-turn message claimed as a turn, a tool_use_id
      # that names no block, and so on. Pass viewer-scoped turns where visibility
      # matters. The `turns:` keyword is required; build it via Turn.group(messages)
      # before calling (keeps this PORO framework-agnostic).
      def self.locate(turns:, kind:, anchor_message_id:, tool_use_id: nil)
        kind = kind.to_s
        return nil unless KINDS.include?(kind)
        return anchor_message_id.nil? ? new(kind: kind) : nil if kind == "conversation"
        return nil if anchor_message_id.nil?

        owning = turns.find { |t| t.messages.any? { |m| m.id == anchor_message_id } }
        return nil unless owning
        message = owning.messages.find { |m| m.id == anchor_message_id }

        case kind
        when "turn"
          return nil unless owning.anchor_id == message.id
        when "prompt"
          return nil unless owning.prompt&.id == message.id
        when "round"
          return nil unless owning.rounds.any? { |r| r.anchor_id == message.id }
        when "tool"
          block_ids = message.blocks.filter_map { |b| b["id"] if b["type"] == "tool_use" }
          # Plain-Ruby equivalent of Rails' .presence: nil/empty string → nil
          tool_use_id = (tool_use_id unless tool_use_id.to_s.empty?) || (block_ids.first if block_ids.one?)
          return nil unless tool_use_id && block_ids.include?(tool_use_id)
        end

        new(kind: kind, message: message, tool_use_id: (tool_use_id if kind == "tool"), turn: owning)
      end

      def initialize(kind:, message: nil, tool_use_id: nil, turn: nil)
        @kind = kind
        @message = message
        @tool_use_id = tool_use_id
        @turn = turn
      end

      def address
        self.class.address_for(kind, message&.id)
      end
    end
  end
end

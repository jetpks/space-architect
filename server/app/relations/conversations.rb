# frozen_string_literal: true

module Architect
  module Relations
    class Conversations < Architect::DB::Relation
      STATUS_MAP    = { 0 => :pending, 1 => :processing, 2 => :completed, 3 => :failed }.freeze
      STATUS_TO_INT = STATUS_MAP.invert.freeze
      STATUS_READ   = ROM::Types::Symbol.constructor { |v| STATUS_MAP.fetch(v.to_i) }

      schema(:conversations, infer: true) do
        attribute :status, ROM::SQL::Types::Integer, read: STATUS_READ

        associations do
          belongs_to :user
          has_many :messages, view: :ordered_by_position
          has_many :annotations
          has_many :conversation_shares, as: :shares
        end
      end
    end
  end
end

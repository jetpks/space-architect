# frozen_string_literal: true

module Architect
  module Relations
    class Runs < Architect::DB::Relation
      STATUS_MAP    = { 0 => :pending, 1 => :live, 2 => :complete, 3 => :failed }.freeze
      STATUS_TO_INT = STATUS_MAP.invert.freeze
      STATUS_READ   = ROM::Types::Symbol.constructor { |v| STATUS_MAP.fetch(v.to_i) }

      schema(:runs, infer: true) do
        attribute :status, ROM::SQL::Types::Integer, read: STATUS_READ

        associations do
          belongs_to :user
        end
      end
    end
  end
end

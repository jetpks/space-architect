# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Runs < Space::Server::DB::Relation
        STATUS_MAP    = { 0 => :pending, 1 => :live, 2 => :complete, 3 => :failed, 4 => :canceled }.freeze
        STATUS_TO_INT = STATUS_MAP.invert.freeze
        STATUS_READ   = ROM::Types::Symbol.constructor { |v| STATUS_MAP.fetch(v.to_i) }

        schema(:runs, infer: true) do
          attribute :status, ROM::SQL::Types::Integer, read: STATUS_READ

          associations do
            belongs_to :user
            belongs_to :space
            belongs_to :iteration
          end
        end
      end
    end
  end
end

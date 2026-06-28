# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Annotations < Space::Server::DB::Relation
        schema(:annotations, infer: true) do
          associations do
            belongs_to :conversation
            belongs_to :user
            belongs_to :anchor_message, relation: :messages
          end
        end
      end
    end
  end
end

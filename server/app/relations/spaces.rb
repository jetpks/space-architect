# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Spaces < Space::Server::DB::Relation
        schema(:spaces, infer: true) do
          associations do
            belongs_to :user
            has_many :iterations
            has_many :artifacts
          end
        end
      end
    end
  end
end

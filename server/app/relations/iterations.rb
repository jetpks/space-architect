# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Iterations < Space::Server::DB::Relation
        schema(:iterations, infer: true) do
          associations do
            belongs_to :space
            has_many :artifacts
            has_many :runs
          end
        end
      end
    end
  end
end

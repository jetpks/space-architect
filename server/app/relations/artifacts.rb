# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Artifacts < Space::Server::DB::Relation
        schema(:artifacts, infer: true) do
          associations do
            belongs_to :space
            belongs_to :iteration
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Providers < Space::Server::DB::Relation
        schema(:providers, infer: true) do
          associations do
            belongs_to :user
          end
        end
      end
    end
  end
end

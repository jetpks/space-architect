# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Profiles < Space::Server::DB::Relation
        schema(:profiles, infer: true) do
          associations do
            belongs_to :user
          end
        end
      end
    end
  end
end

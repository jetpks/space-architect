# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Users < Space::Server::DB::Relation
        schema(:users, infer: true) do
          associations do
            has_many :conversations
            has_many :annotations
          end
        end
      end
    end
  end
end

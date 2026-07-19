# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Jobs < Space::Server::DB::Relation
        schema(:jobs, infer: true) do
          associations do
            belongs_to :user
            belongs_to :run
          end
        end
      end
    end
  end
end

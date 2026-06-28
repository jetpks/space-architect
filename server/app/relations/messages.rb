# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Messages < Space::Server::DB::Relation
        schema(:messages, infer: true) do
          associations do
            belongs_to :conversation
          end
        end

        def ordered_by_position
          order(:position)
        end

        def published
          where(published: true)
        end
      end
    end
  end
end

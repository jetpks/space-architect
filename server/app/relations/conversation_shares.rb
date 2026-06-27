# frozen_string_literal: true

module Space
  module Server
    module Relations
      class ConversationShares < Space::Server::DB::Relation
        schema(:conversation_shares, infer: true) do
          associations do
            belongs_to :conversation
          end
        end
      end
    end
  end
end

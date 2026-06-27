# frozen_string_literal: true

module Architect
  module Relations
    class ConversationShares < Architect::DB::Relation
      schema(:conversation_shares, infer: true) do
        associations do
          belongs_to :conversation
        end
      end
    end
  end
end

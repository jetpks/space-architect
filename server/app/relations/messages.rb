# frozen_string_literal: true

module Architect
  module Relations
    class Messages < Architect::DB::Relation
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

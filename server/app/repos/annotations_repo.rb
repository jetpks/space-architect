# frozen_string_literal: true

module Architect
  module Repos
    class AnnotationsRepo < Architect::DB::Repo
      def for_conversation(conversation_id)
        annotations.where(conversation_id: conversation_id).to_a
      end

      def create(attrs)
        annotations.command(:create).call(attrs)
      end

      def update(id, attrs)
        annotations.by_pk(id).command(:update).call(attrs)
      end

      def delete(id)
        annotations.by_pk(id).command(:delete).call
      end

      def by_pk(id)
        annotations.by_pk(id).one
      end
    end
  end
end

# frozen_string_literal: true

module Space
  module Server
    module Repos
      class MessagesRepo < Space::Server::DB::Repo
        def for_conversation(conversation_id)
          messages.where(conversation_id: conversation_id).order(:position).to_a
        end

        def delete_for_conversation(conversation_id)
          messages.dataset.where(conversation_id: conversation_id).delete
        end

        def published
          messages.where(published: true).to_a
        end

        def create(attrs)
          messages.command(:create).call(attrs)
        end

        def update(id, attrs)
          messages.by_pk(id).command(:update).call(attrs)
        end

        def delete(id)
          messages.by_pk(id).command(:delete).call
        end

        def by_pk(id)
          messages.by_pk(id).one
        end
      end
    end
  end
end

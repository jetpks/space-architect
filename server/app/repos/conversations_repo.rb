# frozen_string_literal: true

module Space
  module Server
    module Repos
      class ConversationsRepo < Space::Server::DB::Repo
        include Space::Server::Deps["repos.conversation_shares_repo"]

        def published
          conversations.where(published: true).to_a
        end

        def by_user(user_id)
          conversations.where(user_id: user_id).to_a
        end

        # Loads a single conversation with :messages and :shares combined, so that
        # struct authz predicates (visible_to?, annotatable_by?, etc.) can operate
        # over preloaded associations without additional queries.
        def with_messages_and_shares(id)
          conversations.by_pk(id).combine(:messages, :shares).one
        end

        # Kept for backward compat; entities/show needs messages only (no shares).
        def with_messages(id)
          conversations.by_pk(id).combine(:messages).one
        end

        # Index scope: published ∪ owned-by-user ∪ shared-with-user, deduped.
        # Anonymous (user nil) → published only.
        # Empty org_ids → safe (Sequel renders empty IN as false literal).
        # Combines :messages and :shares so struct predicates (shared_with?,
        # visible_messages) work without N+1 or NoMethodError.
        def visible_to(user)
          if user.nil?
            return conversations.where(published: true).combine(:messages, :shares).to_a
          end

          share_ids = conversation_shares_repo.granted_conversation_ids(user)
          expr = Sequel.expr(published: true) |
                 Sequel.expr(user_id: user.id) |
                 Sequel.expr(id: share_ids)
          conversations.where(expr).combine(:messages, :shares).to_a
        end

        # Full show combine: user (for serializer owner block), messages (ordered),
        # shares (for can_manage/share_json), and annotations with their authors.
        def for_show(id)
          conversations.by_pk(id).combine(:user, :messages, :shares, annotations: :user).one
        end

        def create(attrs)
          conversations.command(:create).call(attrs)
        end

        def update(id, attrs)
          conversations.by_pk(id).command(:update).call(attrs)
        end

        def delete(id)
          # The DB schema has no CASCADE DELETE on child FKs; delete children first.
          db = conversations.dataset.db
          db.transaction do
            db[:annotations].where(conversation_id: id).delete
            db[:conversation_shares].where(conversation_id: id).delete
            db[:messages].where(conversation_id: id).delete
            conversations.by_pk(id).command(:delete).call
          end
        end

        def by_pk(id)
          conversations.by_pk(id).one
        end
      end
    end
  end
end

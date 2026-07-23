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

        PAGE_SIZE = 50

        # Index scope: published ∪ owned-by-user ∪ shared-with-user, deduped,
        # newest-updated first, paged (page size 50). Anonymous (user nil) →
        # published only. Empty org_ids → safe (Sequel renders empty IN as false
        # literal). Combines :shares so struct predicates (shared_with?) work
        # without N+1. Does NOT combine :messages — the Index action reads the
        # denormalized turns_count column instead; loading every message here is
        # what caused the studio 502 (I36). Callers needing message-backed
        # predicates (visible_messages, visible_to?) must use
        # with_messages_and_shares/for_show. Fetches PAGE_SIZE + 1 rows to detect
        # has_more without a COUNT query.
        def visible_to(user, page: 1)
          if user.nil?
            return paged(conversations.where(published: true), page)
          end

          share_ids = conversation_shares_repo.granted_conversation_ids(user)
          expr = Sequel.expr(published: true) |
                 Sequel.expr(user_id: user.id) |
                 Sequel.expr(id: share_ids)
          paged(conversations.where(expr), page)
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

        # Scoped to the owning user; if dev-artifact duplicates exist for the
        # same (user_id, session_id), the newest row wins.
        def find_by_session_id(user_id, session_id)
          conversations.where(user_id: user_id, session_id: session_id).order(Sequel.desc(:id)).to_a.first
        end

        # The owner's conversation this row was forked/subagent'd from, if any.
        # Newest wins on duplicates; nil-safe when parent_session_id is nil.
        def parent_of(conversation)
          return nil unless conversation.parent_session_id
          conversations
            .where(user_id: conversation.user_id, session_id: conversation.parent_session_id)
            .order(Sequel.desc(:id)).to_a.first
        end

        # The owner's conversations that link back to this row as their parent.
        def children_of(conversation)
          return [] unless conversation.session_id
          conversations
            .where(user_id: conversation.user_id, parent_session_id: conversation.session_id)
            .order(:id).to_a
        end

        private

        def paged(relation, page)
          rows = relation.order(Sequel.desc(:updated_at))
                          .limit(PAGE_SIZE + 1)
                          .offset((page - 1) * PAGE_SIZE)
                          .combine(:shares)
                          .to_a
          { rows: rows.first(PAGE_SIZE), has_more: rows.size > PAGE_SIZE }
        end
      end
    end
  end
end

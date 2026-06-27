# frozen_string_literal: true

module Space
  module Server
    module Repos
      class ConversationSharesRepo < Space::Server::DB::Repo
        def for_conversation(conversation_id)
          conversation_shares.where(conversation_id: conversation_id).to_a
        end

        def create(attrs)
          conversation_shares.command(:create).call(attrs)
        end

        def update(id, attrs)
          conversation_shares.by_pk(id).command(:update).call(attrs)
        end

        def delete(id)
          conversation_shares.by_pk(id).command(:delete).call
        end

        def by_pk(id)
          conversation_shares.by_pk(id).one
        end

        # Returns conversation_ids granted to user (by github_uid or cached org_ids).
        # org_ids may be empty — guarded to avoid an empty IN clause.
        def granted_conversation_ids(user)
          user_ids = conversation_shares
            .where(grantee_kind: "user", github_id: user.github_uid.to_s)
            .dataset.select_map(:conversation_id)

          org_ids = if user.org_ids.any?
            conversation_shares
              .where(grantee_kind: "org", github_id: user.org_ids)
              .dataset.select_map(:conversation_id)
          else
            []
          end

          (user_ids + org_ids).uniq
        end
      end
    end
  end
end

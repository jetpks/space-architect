# frozen_string_literal: true

module Architect
  module Actions
    module Shares
      class Destroy < Architect::Action
        include Architect::Deps["repos.conversations_repo", "repos.conversation_shares_repo"]

        def handle(req, res)
          conversation_id = req.params[:conversation_id].to_i
          conversation = conversations_repo.by_pk(conversation_id)
          halt_not_found(res) unless conversation

          require_owner(req, res, conversation)

          share_id = req.params[:id].to_i
          share = conversation_shares_repo.by_pk(share_id)
          halt_not_found(res) unless share

          conversation_shares_repo.delete(share_id)
          redirect_back_with_flash(req, res,
            fallback: "/conversations/#{conversation_id}",
            notice: "Share removed for #{share.github_login}.")
        end
      end
    end
  end
end

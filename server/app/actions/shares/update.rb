# frozen_string_literal: true

require_relative "../../contracts/update_share"

module Architect
  module Actions
    module Shares
      class Update < Architect::Action
        include Architect::Deps["repos.conversations_repo", "repos.conversation_shares_repo"]

        CONTRACT = Contracts::UpdateShare.new

        def handle(req, res)
          conversation_id = req.params[:conversation_id].to_i
          conversation = conversations_repo.by_pk(conversation_id)
          halt_not_found(res) unless conversation

          require_owner(req, res, conversation)

          share_id = req.params[:id].to_i
          share = conversation_shares_repo.by_pk(share_id)
          halt_not_found(res) unless share

          result = CONTRACT.call(req.params.to_h)
          if result.failure?
            alert = result.errors.to_h.flat_map { |_, msgs|
              msgs.is_a?(Hash) ? msgs.values.flatten : Array(msgs)
            }.join(", ")
            redirect_back_with_flash(req, res, fallback: "/conversations/#{conversation_id}", alert: alert)
          end

          conversation_shares_repo.update(share_id, result.to_h[:share].merge(updated_at: Time.now))
          redirect_back_with_flash(req, res,
            fallback: "/conversations/#{conversation_id}",
            notice: "Access updated for #{share.github_login}.")
        end
      end
    end
  end
end

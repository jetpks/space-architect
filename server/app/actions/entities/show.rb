# frozen_string_literal: true

module Architect
  module Actions
    module Entities
      class Show < Architect::Action
        include Architect::Deps["repos.conversations_repo"]

        def handle(req, res)
          conversation_id = req.params[:conversation_id].to_i
          address = req.params[:address].to_s

          conversation = conversations_repo.with_messages_and_shares(conversation_id)
          halt_not_found(res) unless conversation

          user = current_user(req)

          # Oracle EntitiesController#show has NO require_login and returns
          # head :not_found for every non-grantee (anonymous included) — a uniform
          # 404, unlike conversations/show which nudges anon to log in (401). This
          # asymmetry is deliberate in the oracle; do not mirror show here.
          halt_not_found(res) unless conversation.visible_to?(user)

          parsed = Transcript::Entity.parse(address)
          halt_not_found(res) unless parsed

          # Resolution scoped to viewer-visible messages — unpublished structure
          # cannot be probed by snippet viewers.
          visible = conversation.visible_messages(user)
          turns = Transcript::Turn.group(visible)
          entity = Transcript::Entity.locate(
            turns: turns,
            kind: parsed[:target_kind],
            anchor_message_id: parsed[:anchor_message_id],
            tool_use_id: parsed[:tool_use_id]
          )
          halt_not_found(res) unless entity

          render_json(res, entity_json(entity, conversation_id, entity.address))
        end

        private

        def entity_json(entity, conversation_id, address)
          {
            address: address,
            kind: entity.kind,
            anchor_message_id: entity.message&.id,
            tool_use_id: entity.tool_use_id,
            turn_anchor_id: entity.turn&.anchor_id,
            url: "/conversations/#{conversation_id}/entities/#{address}"
          }
        end
      end
    end
  end
end

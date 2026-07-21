# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Conversations
        class Show < Space::Server::Action
          include Space::Server::Deps["repos.conversations_repo"]

          def handle(req, res)
            id = req.params[:id].to_i
            conversation = conversations_repo.for_show(id)
            halt_not_found(res) unless conversation

            user = current_user(req)

            unless conversation.visible_to?(user)
              # Signed-out viewers get a sign-in nudge; signed-in users see "Not found"
              # (existence-hiding). Mirrors oracle conversations_controller.rb:33-38.
              alert = user ? "Not found." : "Please sign in to view this conversation."
              redirect_with_flash(res, "/", alert: alert)
            end

            owner = conversation.owned_by?(user)
            visible = conversation.visible_messages(user)
            visible_ids = visible.map(&:id).to_set

            # PHASE-0 BLOCKER: Annotation struct lacks targets_conversation? (read-only struct).
            # Inline check `target_kind == "conversation"` is the functional equivalent of the
            # oracle's enum predicate. See lane report D1.
            annotations = conversation.annotations.select do |a|
              a.target_kind == "conversation" || visible_ids.include?(a.anchor_message_id)
            end

            turns = Space::Server::Transcript::Turn.group(visible)

            # parent:/children: are only passed when owner:true, so the serializer's
            # opt-in sentinel keeps the keys off entirely for non-owner/anon viewers.
            links = owner ? { parent: conversations_repo.parent_of(conversation), children: conversations_repo.children_of(conversation) } : {}

            render_inertia(req, res, "Conversations/Show", props: {
              conversation: Serializers::Conversation.conversation_json(conversation, viewer: user, owner: owner, **links),
              turns: turns.map { |t| Serializers::Conversation.turn_json(t, owner: owner) },
              annotations: annotations.map { |a| Serializers::Conversation.annotation_json(a, viewer: user) },
              shares: owner ? conversation.shares.map { |s| Serializers::Conversation.share_json(s) } : nil
            })
          end
        end
      end
    end
  end
end

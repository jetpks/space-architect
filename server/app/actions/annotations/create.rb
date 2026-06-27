# frozen_string_literal: true

require_relative "../../contracts/create_annotation"

module Space
  module Server
    module Actions
      module Annotations
        class Create < Space::Server::Action
          include Space::Server::Deps["repos.conversations_repo", "repos.annotations_repo"]

          CONTRACT = Contracts::CreateAnnotation.new

          def handle(req, res)
            user = require_login(req, res)

            conversation_id = req.params[:conversation_id].to_i
            conversation = conversations_repo.with_messages_and_shares(conversation_id)
            halt_not_found(res) unless conversation

            # Existence-hiding: invisible conversation → redirect to /, "Not found."
            # Mirrors oracle annotations_controller.rb:10. Missing record → 404 JSON (§2c).
            unless conversation.visible_to?(user)
              redirect_with_flash(res, "/", alert: "Not found.")
            end

            # Visibility is not enough: noting requires ownership or a note grant.
            # redirect_back mirrors oracle's redirect_back(fallback_location: conversation).
            unless conversation.annotatable_by?(user)
              redirect_back_with_flash(req, res,
                fallback: "/conversations/#{conversation_id}",
                alert: "Note access required.")
            end

            result = CONTRACT.call(req.params.to_h)
            if result.failure?
              alert = result.errors.to_h.flat_map { |_, msgs|
                msgs.is_a?(Hash) ? msgs.values.flatten : Array(msgs)
              }.join(", ")
              redirect_back_with_flash(req, res, fallback: "/conversations/#{conversation_id}", alert: alert)
            end

            ann_attrs = result.to_h[:annotation]

            # Mirror oracle Annotation model validation: the target must be coherent
            # (e.g. a "round" anchor must be a round-anchor message, not machinery).
            # Uses Entity.locate on the already-loaded messages — no extra query.
            if (kind = ann_attrs[:target_kind])
              turns  = Space::Server::Transcript::Turn.group(conversation.messages)
              entity = Space::Server::Transcript::Entity.locate(
                turns:             turns,
                kind:              kind,
                anchor_message_id: ann_attrs[:anchor_message_id],
                tool_use_id:       ann_attrs[:tool_use_id]
              )
              unless entity
                redirect_back_with_flash(req, res, fallback: "/conversations/#{conversation_id}",
                  alert: "target not found in this conversation")
              end
            end

            attrs = ann_attrs.merge(
              conversation_id: conversation_id,
              user_id: user.id,
              created_at: Time.now,
              updated_at: Time.now
            )
            annotations_repo.create(attrs)
            redirect_back_with_flash(req, res, fallback: "/conversations/#{conversation_id}",
              notice: "Annotation added.")
          end
        end
      end
    end
  end
end

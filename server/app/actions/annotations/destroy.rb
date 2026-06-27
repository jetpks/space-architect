# frozen_string_literal: true

module Architect
  module Actions
    module Annotations
      class Destroy < Architect::Action
        include Architect::Deps["repos.annotations_repo"]

        def handle(req, res)
          user = require_login(req, res)

          id = req.params[:id].to_i
          annotation = annotations_repo.by_pk(id)

          # Mirrors oracle's scoped current_user.annotations.find → RecordNotFound:
          # missing OR not-owned both return 404.
          halt_not_found(res) unless annotation&.owned_by?(user)

          conversation_id = annotation.conversation_id
          annotations_repo.delete(id)
          redirect_back_with_flash(req, res,
            fallback: "/conversations/#{conversation_id}",
            notice: "Annotation removed.")
        end
      end
    end
  end
end

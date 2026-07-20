# frozen_string_literal: true

require "async"
require_relative "../../operations/fetch_models"
require_relative "../../operations/generate_pi_extension"

module Space
  module Server
    module Actions
      module Providers
        # GET /providers/:id/pi_extension (BRIEF I25 §4.6): {extension: {path,
        # content, env_key}, error: null | safe token}, HTTP 200 both ways — same
        # data-not-transport-failure posture and error tokens as Providers::Models.
        # Never surfaces upstream response bodies or resolved secret material, in
        # the response OR logs (no logging at all here).
        class PiExtension < Space::Server::Action
          include Space::Server::Deps["repos.providers_repo"]

          # Class constants (mirrors Providers::Models::FETCH_MODELS) — see that
          # class's comment for the non-memoized-container rationale.
          FETCH_MODELS = Operations::FetchModels.new
          GENERATE_PI_EXTENSION = Operations::GeneratePiExtension.new

          def handle(req, res)
            user = require_login(req, res)

            provider = providers_repo.by_id_for_user(req.params[:id].to_i, user.id)
            halt_not_found(res) unless provider

            model_ids = FETCH_MODELS.call(provider.base_url, provider.api_key_ref)
            extension = GENERATE_PI_EXTENSION.call(provider, model_ids)
            render_json(res, { extension: extension, error: nil })
          rescue Operations::FetchModels::SecretResolutionError
            render_json(res, { extension: nil, error: "secret_resolution_failed" })
          rescue Async::TimeoutError
            render_json(res, { extension: nil, error: "timeout" })
          rescue StandardError
            render_json(res, { extension: nil, error: "upstream_error" })
          end
        end
      end
    end
  end
end

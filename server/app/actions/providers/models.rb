# frozen_string_literal: true

require "async"
require_relative "../../operations/fetch_models"

module Space
  module Server
    module Actions
      module Providers
        # GET /providers/:id/models (BRIEF I22 shape 2): {models: string[], error:
        # null | safe token}, HTTP 200 both ways — the client treats this as data,
        # not a transport-level failure. Never surfaces upstream response bodies or
        # resolved secret material, in the response OR logs (no logging at all here).
        class Models < Space::Server::Action
          include Space::Server::Deps["repos.providers_repo"]

          # Built once as a class constant (mirrors Providers::Create's CONTRACT)
          # rather than resolved per-request via Deps: app/-component container
          # resolution in this app is not memoized (repos, operations, etc. are
          # fresh instances per `App[...]` call), so a Deps-injected fetch_models
          # would not be the same object a test stubs via the container.
          FETCH_MODELS = Operations::FetchModels.new

          def handle(req, res)
            user = require_login(req, res)

            provider = providers_repo.by_id_for_user(req.params[:id].to_i, user.id)
            halt_not_found(res) unless provider

            models = FETCH_MODELS.call(provider.base_url, provider.api_key_ref)
            render_json(res, { models: models, error: nil })
          rescue Operations::FetchModels::SecretResolutionError
            render_json(res, { models: [], error: "secret_resolution_failed" })
          rescue Async::TimeoutError
            render_json(res, { models: [], error: "timeout" })
          rescue StandardError
            render_json(res, { models: [], error: "upstream_error" })
          end
        end
      end
    end
  end
end

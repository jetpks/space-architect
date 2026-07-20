# frozen_string_literal: true

require "async/http/internet"
require "json"
require_relative "../../lib/space/server/jobs/executor/secret_resolver"

module Space
  module Server
    module Operations
      # Server-side models proxy for Providers::Models (BRIEF I22 shape 2):
      # resolves a provider's api_key_ref via the existing op:// SecretResolver
      # (reused, not forked — lib/space/server/jobs/executor/secret_resolver.rb)
      # and GETs {base_url}/v1/models with an explicit timeout. http/secret_resolver
      # are constructor-injected (real by default) so tests can pass fakes and
      # exercise #call directly — no test ever shells `op` or reaches the network.
      class FetchModels
        TIMEOUT_SECONDS = 10
        MODELS_PATH = "/v1/models"

        UpstreamError = Class.new(StandardError)
        SecretResolutionError = Class.new(StandardError)

        def initialize(http: Async::HTTP::Internet.new, secret_resolver: Jobs::Executor::SecretResolver.new)
          @http = http
          @secret_resolver = secret_resolver
        end

        # Returns model ids sorted ascending. Raises SecretResolutionError,
        # UpstreamError, or Async::TimeoutError — Providers::Models maps each to a
        # safe response token, never surfacing upstream bodies or secret values.
        def call(base_url, api_key_ref)
          api_key = resolve_key(api_key_ref)
          response = fetch(base_url, api_key)
          parse(response)
        end

        private

        def resolve_key(api_key_ref)
          return nil if api_key_ref.nil?

          @secret_resolver.call([{"ref" => api_key_ref, "name" => "API_KEY"}])["API_KEY"]
        rescue StandardError => e
          raise SecretResolutionError, e.message
        end

        def fetch(base_url, api_key)
          headers = api_key ? [["authorization", "Bearer #{api_key}"]] : []
          Async::Task.current.with_timeout(TIMEOUT_SECONDS) do
            @http.get("#{base_url}#{MODELS_PATH}", headers)
          end
        end

        def parse(response)
          raise UpstreamError, "status #{response.status}" unless response.status == 200

          data = JSON.parse(response.read)
          data.fetch("data").map { |model| model.fetch("id") }.sort
        rescue JSON::ParserError, KeyError, TypeError, NoMethodError
          raise UpstreamError, "unparseable response"
        ensure
          response&.close
        end
      end
    end
  end
end

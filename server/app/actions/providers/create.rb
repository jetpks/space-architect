# frozen_string_literal: true

require_relative "../../contracts/create_provider"

module Space
  module Server
    module Actions
      module Providers
        class Create < Space::Server::Action
          include Space::Server::Deps["repos.providers_repo"]

          CONTRACT = Contracts::CreateProvider.new

          # CONTRACT's params are already flat (frozen shape 1 — no spec: wrapper),
          # so the field-path mapping is the identity — kept explicit anyway,
          # mirroring Profiles::Create/Jobs::Create's FIELD_PATHS.
          FIELD_PATHS = {
            name:        [:name],
            base_url:    [:base_url],
            api_key_ref: [:api_key_ref],
            flavors:     [:flavors]
          }.freeze

          def handle(req, res)
            user = require_login(req, res)

            result = CONTRACT.call(req.params.to_h)
            redirect_inertia(req, res, "/providers/new", errors: field_errors(result.errors.to_h)) if result.failure?

            create_provider(user, result)
            res.flash["notice"] = "Provider created."
            redirect_inertia(req, res, "/providers")
          end

          private

          def create_provider(user, result)
            now = Time.now
            validated = result.to_h
            providers_repo.create(
              user_id:     user.id,
              name:        validated[:name],
              base_url:    validated[:base_url],
              api_key_ref: validated[:api_key_ref],
              flavors:     validated[:flavors],
              created_at:  now,
              updated_at:  now
            )
          end

          def field_errors(errors)
            FIELD_PATHS.each_with_object({}) do |(field, path), out|
              node = dig_hash(errors, *path)
              out[field] = flatten_messages(node).join(", ") unless node.nil?
            end
          end

          # Plain Hash#dig raises TypeError when an intermediate node is an Array —
          # see Profiles::Create's identical guard for the same crash.
          def dig_hash(node, *path)
            path.reduce(node) do |current, key|
              break nil unless current.is_a?(Hash)

              current[key]
            end
          end

          def flatten_messages(node)
            case node
            when String then [node]
            when Array  then node.flat_map { |v| flatten_messages(v) }
            when Hash   then node.values.flat_map { |v| flatten_messages(v) }
            else []
            end
          end
        end
      end
    end
  end
end

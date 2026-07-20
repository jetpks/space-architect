# frozen_string_literal: true

require_relative "../../contracts/create_profile"

module Space
  module Server
    module Actions
      module Profiles
        class Create < Space::Server::Action
          include Space::Server::Deps["repos.profiles_repo", "repos.providers_repo"]

          CONTRACT = Contracts::CreateProfile.new

          # Maps CONTRACT errors.to_h paths onto Profiles/New.tsx's useForm field
          # names, so redirect_inertia's errors hash lands straight in
          # form.errors per field — mirrors Jobs::Create's FIELD_PATHS.
          FIELD_PATHS = {
            name:          [:name],
            harness_type:  [:spec, :harness, :type],
            harness_model: [:spec, :harness, :model],
            base_url:      [:spec, :harness, :backend, :base_url],
            api_key_ref:   [:spec, :harness, :backend, :api_key_ref],
            args:          [:spec, :harness, :args],
            env:           [:spec, :environment, :env],
            secrets:       [:spec, :environment, :secrets],
            provider_id:   [:provider_id],
            deps:          [:spec, :environment, :deps],
            debs:          [:spec, :environment, :debs],
            gems:          [:spec, :environment, :gems],
            mise:          [:spec, :environment, :mise],
            npm:           [:spec, :environment, :npm],
            files:         [:spec, :environment, :files],
            network:       [:spec, :environment, :permissions, :network],
            mounts:        [:spec, :environment, :permissions, :mounts]
          }.freeze

          def handle(req, res)
            user = require_login(req, res)

            result = CONTRACT.call(req.params.to_h)
            redirect_inertia(req, res, "/profiles/new", errors: field_errors(result.errors.to_h)) if result.failure?

            provider_id = result.to_h[:provider_id]
            if provider_id && providers_repo.by_id_for_user(provider_id, user.id).nil?
              redirect_inertia(req, res, "/profiles/new",
                                errors: { provider_id: "must be one of your providers" })
            end

            profile = create_profile(user, result)
            res.flash["notice"] = "Profile created."
            redirect_inertia(req, res, "/profiles")
          end

          private

          def create_profile(user, result)
            now = Time.now
            validated = result.to_h
            spec = validated[:spec]
            profiles_repo.create(
              user_id:      user.id,
              name:         validated[:name],
              harness_type: spec.dig(:harness, :type),
              spec:         spec,
              provider_id:  validated[:provider_id],
              created_at:   now,
              updated_at:   now
            )
          end

          def field_errors(errors)
            FIELD_PATHS.each_with_object({}) do |(field, path), out|
              node = dig_hash(errors, *path)
              out[field] = flatten_messages(node).join(", ") unless node.nil?
            end
          end

          # Plain Hash#dig raises TypeError when an intermediate node is an Array
          # (e.g. errors[:spec] == ["is missing"] for a payload that omits spec
          # entirely) — that's the exact crash a missing/malformed spec fragment
          # used to cause, so digging must stop instead of exploding.
          def dig_hash(node, *path)
            path.reduce(node) do |current, key|
              break nil unless current.is_a?(Hash)

              current[key]
            end
          end

          # dry-validation renders both array-index errors (environment.deps.1) and
          # our dynamic-key env errors (environment.env.FOO) as nested Hashes within
          # errors.to_h — recurse through Hash/Array structure, collecting the leaf
          # message strings for the field's flat form.errors entry.
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

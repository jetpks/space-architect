# frozen_string_literal: true

require_relative "../../contracts/create_profile"

module Space
  module Server
    module Actions
      module Profiles
        class Create < Space::Server::Action
          include Space::Server::Deps["repos.profiles_repo"]

          CONTRACT = Contracts::CreateProfile.new

          # Maps CONTRACT errors.to_h paths onto Profiles/New.tsx's useForm field
          # names, so redirect_inertia's errors hash lands straight in
          # form.errors per field — mirrors Jobs::Create's FIELD_PATHS.
          FIELD_PATHS = {
            name:          [:name],
            harness_type:  [:harness, :type],
            harness_model: [:harness, :model],
            base_url:      [:harness, :backend, :base_url],
            api_key_ref:   [:harness, :backend, :api_key_ref],
            args:          [:harness, :args],
            env:           [:environment, :env],
            secrets:       [:environment, :secrets],
            deps:          [:environment, :deps],
            npm:           [:environment, :npm],
            files:         [:environment, :files],
            network:       [:environment, :permissions, :network],
            mounts:        [:environment, :permissions, :mounts]
          }.freeze

          def handle(req, res)
            user = require_login(req, res)

            result = CONTRACT.call(req.params.to_h)
            redirect_inertia(req, res, "/profiles/new", errors: field_errors(result.errors.to_h)) if result.failure?

            profile = create_profile(user, result)
            res.flash["notice"] = "Profile created."
            redirect_inertia(req, res, "/profiles")
          end

          private

          def create_profile(user, result)
            now = Time.now
            spec = result.to_h
            profiles_repo.create(
              user_id:      user.id,
              name:         spec[:name],
              harness_type: spec.dig(:harness, :type),
              spec:         spec.reject { |k, _| k == :name },
              created_at:   now,
              updated_at:   now
            )
          end

          def field_errors(errors)
            FIELD_PATHS.each_with_object({}) do |(field, path), out|
              node = errors.dig(*path)
              out[field] = flatten_messages(node).join(", ") unless node.nil?
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

# frozen_string_literal: true

require_relative "../../contracts/create_job"

module Space
  module Server
    module Actions
      module Jobs
        class Create < Space::Server::Action
          include Space::Server::Deps["repos.jobs_repo"]

          CONTRACT = Contracts::CreateJob.new

          # permissions is the one defaultable environment field whose sub-defaults
          # live inside a nested `hash do` block (see create_job.rb) — dry-schema
          # only fills nested-block defaults when the key itself is present, so a
          # fully-omitted `permissions` key is defaulted here instead.
          DEFAULT_PERMISSIONS = { network: false, mounts: [] }.freeze

          # Maps CONTRACT errors.to_h paths onto Jobs/New.tsx's useForm field names,
          # so redirect_inertia's errors hash lands straight in form.errors per field.
          FIELD_PATHS = {
            prompt:        [:prompt],
            harness_model: [:harness, :model],
            base_url:      [:harness, :backend, :base_url],
            api_key_ref:   [:harness, :backend, :api_key_ref],
            args:          [:harness, :args],
            env:           [:environment, :env],
            secrets:       [:environment, :secrets],
            deps:          [:environment, :deps],
            debs:          [:environment, :debs],
            gems:          [:environment, :gems],
            mise:          [:environment, :mise],
            network:       [:environment, :permissions, :network],
            mounts:        [:environment, :permissions, :mounts]
          }.freeze

          def handle(req, res)
            if bearer_request?(req)
              handle_bearer(req, res)
            else
              handle_browser(req, res)
            end
          end

          private

          # Machine flow, byte-compatible with pre-I10 behavior.
          def handle_bearer(req, res)
            user = authenticated_user(req)
            unless user
              res.content_type = JSON_CONTENT_TYPE
              halt 401, JSON.generate(error: "Sign in required.")
            end

            result = CONTRACT.call(req.params.to_h)
            halt_unprocessable(res, result.errors.to_h) if result.failure?

            job = create_job(user, result)
            render_json(res, { id: job.id, status: job.status }, status: 201)
          end

          # Browser/Inertia flow: redirect to the new job on success, back to the
          # form with per-field errors on contract failure.
          def handle_browser(req, res)
            user = require_login(req, res)

            result = CONTRACT.call(req.params.to_h)
            redirect_inertia(req, res, "/jobs/new", errors: field_errors(result.errors.to_h)) if result.failure?

            job = create_job(user, result)
            res.flash["notice"] = "Job queued."
            redirect_inertia(req, res, "/jobs/#{job.id}")
          end

          def create_job(user, result)
            now = Time.now
            jobs_repo.create(user_id: user.id, spec: spec_for(result), created_at: now, updated_at: now)
          end

          def spec_for(result)
            spec = result.to_h
            spec[:environment] = spec[:environment].merge(permissions: DEFAULT_PERMISSIONS) unless spec[:environment].key?(:permissions)
            spec
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

          def verify_csrf_token?(req, *)
            bearer_request?(req) ? false : super
          end
        end
      end
    end
  end
end

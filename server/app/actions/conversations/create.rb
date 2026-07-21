# frozen_string_literal: true

require_relative "../../contracts/create_conversation"

module Space
  module Server
    module Actions
      module Conversations
        class Create < Space::Server::Action
          include Space::Server::Deps[
            "repos.conversations_repo",
            "import_queue"
          ]

          CONTRACT = Contracts::CreateConversation.new

          def handle(req, res)
            if bearer_request?(req)
              handle_bearer(req, res)
            else
              handle_browser(req, res)
            end
          end

          private

          # Machine flow: session-sync CLI uploads (re-)authenticate via Bearer
          # token. session_id is required so the upsert below has something to
          # key on.
          def handle_bearer(req, res)
            user = authenticated_user(req)
            unless user
              res.content_type = JSON_CONTENT_TYPE
              halt 401, JSON.generate(error: "Sign in required.")
            end

            result = CONTRACT.call(req.params.to_h)
            halt_unprocessable(res, result.errors.to_h) if result.failure?

            session_id = result.to_h.dig(:conversation, :session_id)
            unless session_id
              halt_unprocessable(res, conversation: { session_id: ["is missing"] })
            end

            file_param = result.to_h.dig(:conversation, :source_file)
            unless file_param.is_a?(Hash) && file_param[:tempfile]
              halt_unprocessable(res, source_file: ["must be a file upload"])
            end

            data = SourceFileUploader.store(file_param[:tempfile])
            conversation, created = upsert_conversation(user, data, session_id)

            import_queue.call({ "conversation_id" => conversation.id })
            render_json(res, { conversation_id: conversation.id, action: created ? "created" : "updated" },
                        status: created ? 201 : 200)
          end

          # Browser/Inertia flow, byte-compatible with pre-sync behavior; when
          # session_id is present the same upsert semantics apply.
          def handle_browser(req, res)
            user = require_login(req, res)

            result = CONTRACT.call(req.params.to_h)
            if result.failure?
              conv_errors = result.errors.to_h[:conversation]
              errors = conv_errors.is_a?(Hash) ? conv_errors : { conversation: Array(conv_errors) }
              redirect_inertia(req, res, "/conversations/new", errors: errors)
            end

            file_param = result.to_h.dig(:conversation, :source_file)
            unless file_param.is_a?(Hash) && file_param[:tempfile]
              redirect_inertia(req, res, "/conversations/new",
                               errors: { source_file: ["must be a file upload"] })
            end
            data = SourceFileUploader.store(file_param[:tempfile])
            session_id = result.to_h.dig(:conversation, :session_id)

            conversation, = upsert_conversation(user, data, session_id)

            import_queue.call({ "conversation_id" => conversation.id })
            redirect_with_flash(res, "/conversations/#{conversation.id}",
                                notice: "Uploaded — importing now.")
          end

          # Reuses the user's existing (user_id, session_id) row when one exists
          # (re-enqueuing import in place) instead of creating a duplicate;
          # returns [conversation, created].
          def upsert_conversation(user, data, session_id)
            existing = session_id && conversations_repo.find_by_session_id(user.id, session_id)
            now = Time.now

            if existing
              updated = conversations_repo.update(existing.id,
                                                   source_file_data: data,
                                                   session_id: session_id,
                                                   status: 0,
                                                   updated_at: now)
              [updated, false]
            else
              conversation = conversations_repo.create(
                user_id: user.id,
                source_file_data: data,
                session_id: session_id,
                status: 0,
                created_at: now,
                updated_at: now
              )
              [conversation, true]
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

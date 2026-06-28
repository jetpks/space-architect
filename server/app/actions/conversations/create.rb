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
            io = file_param[:tempfile]
            data = SourceFileUploader.store(io)

            now = Time.now
            conversation = conversations_repo.create(
              user_id: user.id,
              source_file_data: data,
              status: 0,
              created_at: now,
              updated_at: now
            )

            import_queue.call({ "conversation_id" => conversation.id })
            redirect_with_flash(res, "/conversations/#{conversation.id}",
                                notice: "Uploaded — importing now.")
          end
        end
      end
    end
  end
end

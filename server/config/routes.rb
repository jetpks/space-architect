# frozen_string_literal: true

module Space
  module Server
    class Routes < Hanami::Routes
      mount HanamiHealthcheck::Endpoint.new, at: "/up"

      # Auth — OmniAuth callback (GET for redirect, POST for form submission)
      get  "/auth/:provider/callback", to: "sessions.create"
      post "/auth/:provider/callback", to: "sessions.create"
      get  "/auth/failure",            to: "sessions.failure"

      # Logout — both GET (link) and DELETE (form)
      get    "/logout", to: "sessions.destroy"
      delete "/logout", to: "sessions.destroy"

      # Root and conversations list (same action, two paths — rows 4 & 5)
      root to: "conversations.index"
      get  "/conversations", to: "conversations.index"

      # Conversations
      get    "/conversations/new",          to: "conversations.new"
      post   "/conversations",              to: "conversations.create"
      get    "/conversations/:id",          to: "conversations.show"
      patch  "/conversations/:id/publish",  to: "conversations.publish"
      delete "/conversations/:id",          to: "conversations.destroy"

      # Annotations (nested create, shallow destroy)
      post   "/conversations/:conversation_id/annotations", to: "annotations.create"
      delete "/annotations/:id",                            to: "annotations.destroy"

      # Shares (nested CRUD)
      post   "/conversations/:conversation_id/shares",       to: "shares.create"
      patch  "/conversations/:conversation_id/shares/:id",   to: "shares.update"
      delete "/conversations/:conversation_id/shares/:id",   to: "shares.destroy"

      # Entities (derived from messages — full PORO stack)
      get "/conversations/:conversation_id/entities/:address", to: "entities.show"

      # Messages (shallow member — publish toggle)
      patch "/messages/:id/publish", to: "messages.publish"

      # Runs (live streaming — skeleton routes, ingest/stream bodies filled in I04/I05)
      get  "/runs",             to: "runs.index"
      post "/runs",             to: "runs.create"
      post "/runs/:id/ingest",  to: "runs.ingest"
      get  "/runs/:id/stream",  to: "runs.stream"
      get  "/runs/:id",         to: "runs.show"

      # Spaces
      get "/spaces",                    to: "spaces.index"
      get "/spaces/:id",                to: "spaces.show"
      get "/spaces/:id/runs/:run_id",   to: "spaces.run"
    end
  end
end

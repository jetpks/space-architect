# frozen_string_literal: true

require_relative "../test_helper"
require "rack/mock"
require "json"
require "omniauth"

# Test helper uses hanami/prepare (not hanami/boot), so providers don't auto-start.
# Start :inertia so shared_props (flash, current_user) are configured before tests.
# Start :redis so the ingest action can access the Redis client.
Space::Server::App.start(:inertia)
Space::Server::App.start(:redis)

module ActionTestHelper
  def app = Space::Server::App

  def get(path, params: {})
    query = params.empty? ? "" : URI.encode_www_form(params)
    path_with_query = params.empty? ? path : "#{path}?#{query}"
    env = Rack::MockRequest.env_for(path_with_query, "REQUEST_METHOD" => "GET")
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    app.call(env)
  end

  # GET with X-Inertia + X-Inertia-Version headers for hermetic render tests.
  # The version matches ViteRuby#digest (hashes app/frontend sources, no manifest).
  # Accepts an optional cookie: override so flash round-trips can supply the
  # redirect's set-cookie rather than @session_cookie.
  def inertia_get(path, params: {}, cookie: nil)
    vite_version = Space::Server::App["vite"].digest
    query = params.empty? ? "" : URI.encode_www_form(params)
    path_with_query = params.empty? ? path : "#{path}?#{query}"
    env = Rack::MockRequest.env_for(path_with_query, "REQUEST_METHOD" => "GET")
    env["HTTP_X_INERTIA"] = "true"
    env["HTTP_X_INERTIA_VERSION"] = vite_version
    effective_cookie = cookie || @session_cookie
    env["HTTP_COOKIE"] = effective_cookie if effective_cookie
    app.call(env)
  end

  def post(path, params: {}, bearer: nil)
    body = URI.encode_www_form(flatten_params(params))
    env = Rack::MockRequest.env_for(
      path,
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      input: body
    )
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" unless bearer.nil?
    app.call(env)
  end

  def patch(path, params: {})
    body = URI.encode_www_form(flatten_params(params))
    env = Rack::MockRequest.env_for(
      path,
      "REQUEST_METHOD" => "PATCH",
      "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      input: body
    )
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    app.call(env)
  end

  # PATCH with X-Inertia so the middleware coerces 302→303 (COERCIBLE_METHODS).
  def inertia_patch(path, params: {})
    body = URI.encode_www_form(flatten_params(params))
    env = Rack::MockRequest.env_for(
      path,
      "REQUEST_METHOD" => "PATCH",
      "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      input: body
    )
    env["HTTP_X_INERTIA"] = "true"
    env["HTTP_X_INERTIA_VERSION"] = Space::Server::App["vite"].digest
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    app.call(env)
  end

  def post_raw(path, body:, content_type: "application/x-ndjson", bearer: nil)
    env = Rack::MockRequest.env_for(
      path,
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => content_type,
      "CONTENT_LENGTH" => body.bytesize.to_s,
      input: body
    )
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" unless bearer.nil?
    app.call(env)
  end

  def delete(path)
    env = Rack::MockRequest.env_for(path, "REQUEST_METHOD" => "DELETE")
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    app.call(env)
  end

  # DELETE with X-Inertia so the middleware coerces 302→303.
  def inertia_delete(path)
    env = Rack::MockRequest.env_for(path, "REQUEST_METHOD" => "DELETE")
    env["HTTP_X_INERTIA"] = "true"
    env["HTTP_X_INERTIA_VERSION"] = Space::Server::App["vite"].digest
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    app.call(env)
  end

  def parse_json(body_parts)
    body_str = body_parts.respond_to?(:join) ? body_parts.join : body_parts.to_s
    JSON.parse(body_str)
  end

  def setup_db
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :runs, :users].each { |t| conn[t].delete }
  end

  # Establish a signed-in session via the real OmniAuth callback stack.
  def sign_in(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github",
      uid: user.github_uid,
      info: {
        nickname: user.username,
        name:     user.name.to_s.empty? ? user.username : user.name,
        email:    user.email.to_s.empty? ? "#{user.github_uid}@test.example" : user.email,
        image:    user.avatar_url
      },
      credentials: nil
    )
    _, headers, _ = post("/auth/github/callback")
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    @session_cookie = headers["set-cookie"]&.split(";")&.first
  end

  def sign_out
    @session_cookie = nil
  end

  # Capture flash from a redirect response by following up with an inertia_get("/").
  # Returns the props.flash hash from the next page object.
  # Pass `cookie:` to use an explicit cookie (e.g. from a redirect response's set-cookie
  # while @session_cookie is from a different session state).
  def flash_from_redirect(redirect_headers, path: "/", cookie: nil)
    redirect_cookie = redirect_headers["set-cookie"]&.split(";")&.first
    effective_cookie = cookie || redirect_cookie
    return {} unless effective_cookie
    _, _, body = inertia_get(path, cookie: effective_cookie)
    # Flash lives at props.flash in the Inertia page object, not at the top level.
    parse_json(body).dig("props", "flash") || {}
  end

  def get_stream(path, extra_env: {})
    env = Rack::MockRequest.env_for(path, "REQUEST_METHOD" => "GET")
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    env.merge!(extra_env)
    app.call(env)
  end

  def collect_sse_chunks(body, timeout: 5)
    chunks = []
    mock_stream = MockStream.new(chunks)
    Sync do |task|
      task.with_timeout(timeout) do
        body.call(mock_stream)
      end
    rescue Async::TimeoutError
    end
    chunks
  end

  class MockStream
    def initialize(chunks)
      @chunks = chunks
    end

    def <<(data)
      @chunks << data
      self
    end

    def close(error = nil)
    end
  end

  private

  def flatten_params(hash, prefix = nil)
    hash.flat_map do |key, value|
      full_key = prefix ? "#{prefix}[#{key}]" : key.to_s
      if value.is_a?(Hash)
        flatten_params(value, full_key)
      else
        [[full_key, value.to_s]]
      end
    end
  end
end

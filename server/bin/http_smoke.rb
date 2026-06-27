#!/usr/bin/env ruby
# frozen_string_literal: true

ENV["HANAMI_ENV"] ||= "test"

# In-process boot + route-resolve smoke (G2/G6).
# Usage: bundle exec ruby bin/http_smoke.rb
# Exit 0 = PASS; exit 1 = FAIL (error printed to stderr)
#
# Auth-required routes now return 401 (not 5xx) for anonymous callers.
# The important invariant: no route returns 5xx.

require "hanami/boot"
require "rack/mock"

INERTIA_GET_PATHS = %w[/ /conversations /conversations/new /conversations/1].freeze

def smoke_call(verb, path)
  env = Rack::MockRequest.env_for(path, "REQUEST_METHOD" => verb)
  if verb == "GET" && INERTIA_GET_PATHS.include?(path)
    env["HTTP_X_INERTIA"] = "true"
    env["HTTP_X_INERTIA_VERSION"] = Architect::App["vite"].digest
  end
  Architect::App.call(env)
end

failures = []

# Routes that must NOT 5xx (correct authz status for anon is fine)
ANON_ROUTES = [
  ["GET",    "/up"],
  ["GET",    "/auth/github/callback"],
  ["POST",   "/auth/github/callback"],
  ["GET",    "/auth/failure"],
  ["GET",    "/logout"],
  ["DELETE", "/logout"],
  ["GET",    "/"],
  ["GET",    "/conversations"],
  # Auth-required routes — anon → 401, not 5xx
  ["GET",    "/conversations/new"],
  ["POST",   "/conversations"],
  ["GET",    "/conversations/1"],
  ["PATCH",  "/conversations/1/publish"],
  ["DELETE", "/conversations/1"],
  ["POST",   "/conversations/1/annotations"],
  ["DELETE", "/annotations/1"],
  ["POST",   "/conversations/1/shares"],
  ["PATCH",  "/conversations/1/shares/2"],
  ["DELETE", "/conversations/1/shares/2"],
  ["GET",    "/conversations/1/entities/turn-42"],
  ["PATCH",  "/messages/1/publish"],
].freeze

ANON_ROUTES.each do |verb, path|
  begin
    status, _, _ = smoke_call(verb, path)
    if status >= 500
      failures << "#{verb} #{path} → #{status} (server error)"
    end
  rescue => e
    failures << "#{verb} #{path} → #{e.class}: #{e.message}"
  end
end

# GET / must return 200 (published-only list; empty DB → [])
root_status, root_headers, root_body = smoke_call("GET", "/")
unless root_status == 200
  failures << "GET / → expected 200, got #{root_status}"
end

# GET /up must return 200
up_status, _, _ = smoke_call("GET", "/up")
unless up_status == 200
  failures << "GET /up → expected 200, got #{up_status}"
end

# Auth-required write endpoints must return 401 for anon (not 5xx, not 200)
AUTH_REQUIRED = [
  ["GET",    "/conversations/new"],
  ["POST",   "/conversations"],
  ["PATCH",  "/conversations/1/publish"],
  ["DELETE", "/conversations/1"],
  ["POST",   "/conversations/1/annotations"],
  ["DELETE", "/annotations/1"],
  ["POST",   "/conversations/1/shares"],
  ["PATCH",  "/conversations/1/shares/2"],
  ["DELETE", "/conversations/1/shares/2"],
  ["PATCH",  "/messages/1/publish"],
].freeze

AUTH_REQUIRED.each do |verb, path|
  begin
    status, _, _ = smoke_call(verb, path)
    # 4c-3 inverted guards return 3xx redirects for anon; resource-lookup-first actions
    # (shares) return 404 against empty DB. The security invariant is: no unauthorized
    # 200 and no 5xx. Accept any 3xx-4xx.
    if status == 200 || status >= 500
      failures << "#{verb} #{path} → expected non-200/non-5xx for anon, got #{status}"
    end
  rescue => e
    failures << "#{verb} #{path} → #{e.class}: #{e.message}"
  end
end

if failures.empty?
  puts "SMOKE OK — #{ANON_ROUTES.size} routes resolved, GET / → #{root_status}, GET /up → #{up_status}"
  exit 0
else
  $stderr.puts "SMOKE FAIL:"
  failures.each { |f| $stderr.puts "  - #{f}" }
  exit 1
end

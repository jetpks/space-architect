# auto_register: false
# frozen_string_literal: true

require "net/http"
require "base64"
require "json"

module Architect
  # Thin Net::HTTP client for GitHub REST API calls: resolving a typed login
  # to a stable account (share grants) and listing org memberships from a fresh
  # OAuth token (cached at sign-in). Class methods are the test seam.
  # Net::HTTP is fiber-native under Falcon's Fiber.scheduler.
  module Github
    class Error < StandardError; end
    class NotFound < Error; end

    Account = Data.define(:id, :login, :kind)

    LOGIN_FORMAT = /\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,38})\z/

    def self.lookup(login)
      raise NotFound, "invalid login" unless login.match?(LOGIN_FORMAT)

      data = request("/users/#{login}", app_auth_header)
      Account.new(
        id: data["id"].to_s,
        login: data["login"],
        kind: data["type"] == "Organization" ? "org" : "user"
      )
    end

    def self.user_orgs(token)
      request("/user/orgs?per_page=100", "Bearer #{token}")
        .map { |org| {"id" => org["id"].to_s, "login" => org["login"]} }
    end

    def self.request(path, authorization)
      uri = URI("https://api.github.com#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5

      req = Net::HTTP::Get.new(uri)
      req["Accept"] = "application/vnd.github+json"
      req["Authorization"] = authorization if authorization

      response = http.request(req)
      case response
      when Net::HTTPSuccess then JSON.parse(response.body)
      when Net::HTTPNotFound then raise NotFound, path
      else raise Error, "GitHub API #{response.code} for #{path}"
      end
    rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, JSON::ParserError => e
      raise Error, e.message
    end
    private_class_method :request

    def self.app_auth_header
      id     = Architect::App["settings"].github_client_id
      secret = Architect::App["settings"].github_client_secret
      return nil if id.nil? || id.empty? || secret.nil? || secret.empty?

      "Basic #{Base64.strict_encode64("#{id}:#{secret}")}"
    end
    private_class_method :app_auth_header
  end
end

# frozen_string_literal: true

require "async/http/client"
require "async/http/endpoint"
require "json"

module SpaceArchitect
  class RunCreator
    def initialize(host, token, client: nil)
      @host   = host.chomp("/")
      @token  = token
      @client = client
    end

    # POSTs to /runs and returns the integer run id.
    # Raises SpaceArchitect::Error on any failure — never returns nil.
    def create
      Sync do
        if @client
          response = @client.post("/runs", headers: headers, body: nil)
          parse_response(response)
        else
          Async::HTTP::Client.open(Async::HTTP::Endpoint.parse(@host)) do |c|
            response = c.post("/runs", headers: headers, body: nil)
            parse_response(response)
          end
        end
      end
    end

    private

    def headers
      [
        ["authorization", "Bearer #{@token}"],
        ["content-type",  "application/json"]
      ]
    end

    def parse_response(response)
      status = response.status
      body   = response.read || ""
      raise Error, "POST /runs failed (#{status}): #{body[0, 200]}" unless status == 201

      parsed = JSON.parse(body)
      id     = parsed["id"]
      raise Error, "POST /runs: missing or non-integer id in response: #{body[0, 200]}" \
        unless id.is_a?(Integer)

      id
    end
  end
end

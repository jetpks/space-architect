# frozen_string_literal: true

require_relative "test_helper"
require "async/http/mock"
require "async/http/client"
require "protocol/http/response"
require "json"

class RunCreatorTest < Space::ArchitectTest
  # (a) POSTs to /runs with the bearer token and returns the integer id.
  def test_create_posts_to_runs_with_auth_and_returns_id
    mock_endpoint = Async::HTTP::Mock::Endpoint.new

    Sync do
      server_task = Async do
        mock_endpoint.run do |request|
          assert_equal "POST",       request.method
          assert_equal "/runs",      request.path
          assert_equal "Bearer secret-token", request.headers["authorization"]
          request.body&.read
          Protocol::HTTP::Response[201, [["content-type", "application/json"]],
                                   [JSON.generate({ id: 42, status: "pending" })]]
        end
      end

      client  = Async::HTTP::Client.new(mock_endpoint)
      creator = Space::Architect::RunCreator.new("http://localhost", "secret-token", client: client)
      id      = creator.create

      assert_equal 42, id

      client.close
      server_task.stop
    end
  end

  # (b) Non-201 response raises Space::Core::Error.
  def test_create_raises_on_non_201_response
    mock_endpoint = Async::HTTP::Mock::Endpoint.new

    Sync do
      server_task = Async do
        mock_endpoint.run do |_request|
          Protocol::HTTP::Response[401, [["content-type", "application/json"]],
                                   [JSON.generate({ error: "Unauthorized" })]]
        end
      end

      client  = Async::HTTP::Client.new(mock_endpoint)
      creator = Space::Architect::RunCreator.new("http://localhost", "bad-token", client: client)

      assert_raises(Space::Core::Error) { creator.create }

      client.close
      server_task.stop
    end
  end

  # (c-i) 201 with no id field raises Space::Core::Error.
  def test_create_raises_on_missing_id_in_201_body
    mock_endpoint = Async::HTTP::Mock::Endpoint.new

    Sync do
      server_task = Async do
        mock_endpoint.run do |_request|
          Protocol::HTTP::Response[201, [["content-type", "application/json"]],
                                   [JSON.generate({ status: "pending" })]]
        end
      end

      client  = Async::HTTP::Client.new(mock_endpoint)
      creator = Space::Architect::RunCreator.new("http://localhost", "tok", client: client)

      assert_raises(Space::Core::Error) { creator.create }

      client.close
      server_task.stop
    end
  end

  # (c-ii) 201 with non-integer id raises Space::Core::Error.
  def test_create_raises_on_non_integer_id_in_201_body
    mock_endpoint = Async::HTTP::Mock::Endpoint.new

    Sync do
      server_task = Async do
        mock_endpoint.run do |_request|
          Protocol::HTTP::Response[201, [["content-type", "application/json"]],
                                   [JSON.generate({ id: "not-an-int", status: "pending" })]]
        end
      end

      client  = Async::HTTP::Client.new(mock_endpoint)
      creator = Space::Architect::RunCreator.new("http://localhost", "tok", client: client)

      assert_raises(Space::Core::Error) { creator.create }

      client.close
      server_task.stop
    end
  end
end

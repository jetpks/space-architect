# frozen_string_literal: true

require_relative "../../../../test_helper"
require "space/server/boot/ingest_token"

class IngestTokenTest < Minitest::Test
  class FakeResolver
    def initialize(values: {}, error: nil)
      @values = values
      @error = error
      @calls = []
    end

    attr_reader :calls

    def call(secret_refs)
      @calls << secret_refs
      raise @error if @error

      secret_refs.to_h { |secret| [secret["name"], @values.fetch(secret["name"])] }
    end
  end

  def test_pass_through_uses_existing_env_token_without_calling_resolver
    resolver = FakeResolver.new
    env = {"INGEST_TOKEN" => "already-set"}

    result = Space::Server::Boot::IngestToken.new(resolver: resolver).resolve!(env: env)

    assert_equal "already-set", result
    assert_equal "already-set", env["INGEST_TOKEN"]
    assert_empty resolver.calls
  end

  def test_resolves_default_ref_when_env_token_absent
    resolver = FakeResolver.new(values: {"INGEST_TOKEN" => "resolved-value"})
    env = {}

    result = Space::Server::Boot::IngestToken.new(resolver: resolver).resolve!(env: env)

    assert_equal "resolved-value", result
    assert_equal "resolved-value", env["INGEST_TOKEN"]
    assert_equal [[{"ref" => "op://ansible/space-architect-server/ingest-token", "name" => "INGEST_TOKEN"}]],
                 resolver.calls
  end

  def test_resolves_overridden_ref_from_env
    resolver = FakeResolver.new(values: {"INGEST_TOKEN" => "resolved-value"})
    env = {"INGEST_TOKEN_REF" => "op://vault/item/field"}

    Space::Server::Boot::IngestToken.new(resolver: resolver).resolve!(env: env)

    assert_equal [[{"ref" => "op://vault/item/field", "name" => "INGEST_TOKEN"}]], resolver.calls
  end

  def test_raises_and_leaves_env_untouched_when_resolver_raises
    resolver = FakeResolver.new(error: "op read failed for op://ansible/space-architect-server/ingest-token")
    env = {}

    assert_raises(RuntimeError) { Space::Server::Boot::IngestToken.new(resolver: resolver).resolve!(env: env) }
    assert_nil env["INGEST_TOKEN"]
  end

  def test_raises_and_leaves_env_untouched_when_resolved_value_is_empty
    resolver = FakeResolver.new(values: {"INGEST_TOKEN" => ""})
    env = {}

    assert_raises(RuntimeError) { Space::Server::Boot::IngestToken.new(resolver: resolver).resolve!(env: env) }
    assert_nil env["INGEST_TOKEN"]
  end
end

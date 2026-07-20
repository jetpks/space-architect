# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../app/contracts/create_provider"

class CreateProviderContractTest < Minitest::Test
  def contract = Space::Server::Contracts::CreateProvider.new

  def valid_params
    {
      name: "my-gateway",
      base_url: "https://api.example.com/v1",
      api_key_ref: "op://vault/item",
      flavors: ["openai", "anthropic"]
    }
  end

  def test_valid_params_succeeds
    r = contract.call(valid_params)
    assert r.success?, r.errors.to_h.inspect
  end

  def test_valid_params_without_api_key_ref_succeeds
    r = contract.call(valid_params.reject { |k, _| k == :api_key_ref })
    assert r.success?, r.errors.to_h.inspect
    refute r.to_h.key?(:api_key_ref)
  end

  def test_rejects_missing_name
    r = contract.call(valid_params.reject { |k, _| k == :name })
    assert r.failure?
    assert_includes r.errors.to_h[:name], "is missing"
  end

  def test_rejects_empty_name
    r = contract.call(valid_params.merge(name: ""))
    assert r.failure?
    assert_includes r.errors.to_h[:name], "must be filled"
  end

  def test_rejects_non_http_base_url
    r = contract.call(valid_params.merge(base_url: "not-a-url"))
    assert r.failure?
    assert_includes r.errors.to_h[:base_url], "is in invalid format"
  end

  def test_rejects_raw_key_api_key_ref
    r = contract.call(valid_params.merge(api_key_ref: "sk-abc123"))
    assert r.failure?
    assert_includes r.errors.to_h[:api_key_ref], "is in invalid format"
  end

  def test_rejects_empty_flavors
    r = contract.call(valid_params.merge(flavors: []))
    assert r.failure?
    assert_includes r.errors.to_h[:flavors], "must be filled"
  end

  def test_rejects_missing_flavors
    r = contract.call(valid_params.reject { |k, _| k == :flavors })
    assert r.failure?
    assert_includes r.errors.to_h[:flavors], "is missing"
  end

  def test_rejects_unknown_flavor
    r = contract.call(valid_params.merge(flavors: ["openai", "bogus"]))
    assert r.failure?
    assert_equal ["must be one of: openai, anthropic"], r.errors.to_h[:flavors][1]
  end

  def test_rejects_duplicate_flavors
    r = contract.call(valid_params.merge(flavors: ["openai", "openai"]))
    assert r.failure?
    assert_includes r.errors.to_h[:flavors], "must not contain duplicates"
  end
end

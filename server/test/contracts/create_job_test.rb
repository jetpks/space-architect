# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../app/contracts/create_job"

class CreateJobContractTest < Minitest::Test
  def contract = Space::Server::Contracts::CreateJob.new

  def valid_spec
    {
      harness: {
        type: "claude", model: "claude-sonnet-5",
        backend: { base_url: "https://api.example.com/v1", api_key_ref: "op://vault/item" },
        args: ["--flag"]
      },
      prompt: "do the thing",
      environment: {
        env: { FOO: "bar" },
        secrets: [{ ref: "op://vault/item2", name: "API_KEY" }],
        deps: ["git"],
        files: "sha256:abc",
        permissions: { network: true, mounts: ["/tmp"] }
      }
    }
  end

  def test_valid_full_spec_succeeds
    r = contract.call(valid_spec)
    assert r.success?, r.errors.to_h.inspect
  end

  def test_valid_minimal_spec_applies_defaults
    r = contract.call(
      harness: { type: "claude", model: "sonnet", backend: { base_url: "https://api.example.com" } },
      prompt: "hi",
      environment: {}
    )
    assert r.success?, r.errors.to_h.inspect
    env = r.to_h[:environment]
    assert_equal({}, env[:env])
    assert_equal [], env[:secrets]
    assert_equal [], env[:deps]
    refute env.key?(:files)
  end

  def test_permissions_defaults_apply_when_permissions_hash_present
    r = contract.call(valid_spec.merge(environment: valid_spec[:environment].merge(permissions: {})))
    assert r.success?, r.errors.to_h.inspect
    assert_equal({ network: false, mounts: [] }, r.to_h[:environment][:permissions])
  end

  def test_rejects_missing_prompt
    r = contract.call(valid_spec.reject { |k, _| k == :prompt })
    assert r.failure?
    assert_includes r.errors.to_h[:prompt], "is missing"
  end

  def test_rejects_empty_prompt
    r = contract.call(valid_spec.merge(prompt: ""))
    assert r.failure?
    assert_includes r.errors.to_h[:prompt], "must be filled"
  end

  def test_rejects_unknown_harness_type
    r = contract.call(valid_spec.merge(harness: valid_spec[:harness].merge(type: "gpt4")))
    assert r.failure?
    assert r.errors.to_h.dig(:harness, :type)
  end

  def test_rejects_non_http_base_url
    r = contract.call(valid_spec.merge(harness: valid_spec[:harness].merge(backend: { base_url: "not-a-url" })))
    assert r.failure?
    assert r.errors.to_h.dig(:harness, :backend, :base_url)
  end

  def test_rejects_ftp_base_url
    r = contract.call(valid_spec.merge(harness: valid_spec[:harness].merge(backend: { base_url: "ftp://example.com/x" })))
    assert r.failure?
    assert r.errors.to_h.dig(:harness, :backend, :base_url)
  end

  def test_rejects_secret_ref_not_op
    r = contract.call(valid_spec.merge(environment: { secrets: [{ ref: "not-op", name: "X" }] }))
    assert r.failure?
    assert r.errors.to_h.dig(:environment, :secrets, 0, :ref)
  end

  def test_rejects_api_key_ref_not_op
    r = contract.call(valid_spec.merge(harness: valid_spec[:harness].merge(
      backend: valid_spec[:harness][:backend].merge(api_key_ref: "sk-plaintext-secret")
    )))
    assert r.failure?
    assert r.errors.to_h.dig(:harness, :backend, :api_key_ref)
  end

  def test_rejects_empty_deps_element
    r = contract.call(valid_spec.merge(environment: { deps: ["git", ""] }))
    assert r.failure?
    assert r.errors.to_h.dig(:environment, :deps, 1)
  end

  def test_unknown_top_level_keys_are_dropped
    r = contract.call(valid_spec.merge(evil: "x"))
    assert r.success?
    refute r.to_h.key?(:evil)
  end
end

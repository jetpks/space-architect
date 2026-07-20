# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../app/contracts/create_profile"

class CreateProfileContractTest < Minitest::Test
  def contract = Space::Server::Contracts::CreateProfile.new

  def valid_spec
    {
      name: "my-profile",
      harness: {
        type: "claude", model: "claude-sonnet-5",
        backend: { base_url: "https://api.example.com/v1", api_key_ref: "op://vault/item" },
        args: ["--flag"]
      },
      environment: {
        env: { FOO: "bar" },
        secrets: [{ ref: "op://vault/item2", name: "API_KEY" }],
        deps: ["git"],
        npm: ["cowsay"],
        files: [{ path: "/root/.pi/agent/extensions/local-inference.ts", content_b64: "Zm9v" }],
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
      name: "minimal",
      harness: { type: "claude", model: "sonnet", backend: { base_url: "https://api.example.com" } },
      environment: {}
    )
    assert r.success?, r.errors.to_h.inspect
    env = r.to_h[:environment]
    assert_equal({}, env[:env])
    assert_equal [], env[:secrets]
    assert_equal [], env[:deps]
    assert_equal [], env[:npm]
    assert_equal [], env[:files]
  end

  def test_rejects_missing_name
    r = contract.call(valid_spec.reject { |k, _| k == :name })
    assert r.failure?
    assert_includes r.errors.to_h[:name], "is missing"
  end

  def test_rejects_empty_name
    r = contract.call(valid_spec.merge(name: ""))
    assert r.failure?
    assert_includes r.errors.to_h[:name], "must be filled"
  end

  def test_rejects_unknown_harness_type
    r = contract.call(valid_spec.merge(harness: valid_spec[:harness].merge(type: "gpt4")))
    assert r.failure?
    assert r.errors.to_h.dig(:harness, :type)
  end

  def test_accepts_pi_harness_type
    r = contract.call(valid_spec.merge(harness: valid_spec[:harness].merge(type: "pi")))
    assert r.success?, r.errors.to_h.inspect
    assert_equal "pi", r.to_h.dig(:harness, :type)
  end

  def test_rejects_non_http_base_url
    r = contract.call(valid_spec.merge(harness: valid_spec[:harness].merge(backend: { base_url: "not-a-url" })))
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

  def test_rejects_non_string_env_value
    r = contract.call(valid_spec.merge(environment: valid_spec[:environment].merge(env: { FOO: 1 })))
    assert r.failure?
    assert r.errors.to_h.dig(:environment, :env, :FOO)
  end

  def test_rejects_relative_file_path
    files = [{ path: "relative/path.ts", content_b64: "Zm9v" }]
    r = contract.call(valid_spec.merge(environment: valid_spec[:environment].merge(files: files)))
    assert r.failure?
    assert r.errors.to_h.dig(:environment, :files, 0, :path)
  end

  def test_rejects_dot_dot_bearing_file_path
    files = [{ path: "/root/../etc/passwd", content_b64: "Zm9v" }]
    r = contract.call(valid_spec.merge(environment: valid_spec[:environment].merge(files: files)))
    assert r.failure?
    assert r.errors.to_h.dig(:environment, :files, 0, :path)
  end

  def test_unknown_top_level_keys_are_dropped
    r = contract.call(valid_spec.merge(evil: "x"))
    assert r.success?
    refute r.to_h.key?(:evil)
  end

  def test_no_prompt_workspace_or_provenance_fields
    r = contract.call(valid_spec)
    assert r.success?, r.errors.to_h.inspect
    refute r.to_h.key?(:prompt)
    refute r.to_h.key?(:workspace)
    refute r.to_h.key?(:provenance)
  end
end

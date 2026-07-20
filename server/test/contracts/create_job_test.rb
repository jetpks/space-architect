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
      harness: { type: "claude", model: "sonnet", backend: { base_url: "https://api.example.com" } },
      prompt: "hi",
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

  def test_accepts_pi_harness_type
    r = contract.call(valid_spec.merge(harness: valid_spec[:harness].merge(type: "pi")))
    assert r.success?, r.errors.to_h.inspect
    assert_equal "pi", r.to_h.dig(:harness, :type)
  end

  def test_accepts_opencode_harness_type
    r = contract.call(valid_spec.merge(harness: valid_spec[:harness].merge(type: "opencode")))
    assert r.success?, r.errors.to_h.inspect
    assert_equal "opencode", r.to_h.dig(:harness, :type)
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

  # --- environment.debs / gems / mise (I24) --------------------------------

  def test_accepts_debs_gems_mise_and_defaults_absent_keys
    r = contract.call(valid_spec.merge(environment: valid_spec[:environment].merge(debs: ["jq"], gems: ["rspec"], mise: ["ruby@3.3"])))
    assert r.success?, r.errors.to_h.inspect
    assert_equal ["jq"], r.to_h.dig(:environment, :debs)
    assert_equal ["rspec"], r.to_h.dig(:environment, :gems)
    assert_equal ["ruby@3.3"], r.to_h.dig(:environment, :mise)
  end

  def test_debs_gems_mise_default_to_empty_array
    r = contract.call(
      harness: { type: "claude", model: "sonnet", backend: { base_url: "https://api.example.com" } },
      prompt: "hi",
      environment: {}
    )
    assert r.success?, r.errors.to_h.inspect
    env = r.to_h[:environment]
    assert_equal [], env[:debs]
    assert_equal [], env[:gems]
    assert_equal [], env[:mise]
  end

  def test_rejects_empty_debs_element
    r = contract.call(valid_spec.merge(environment: { debs: ["jq", ""] }))
    assert r.failure?
    assert r.errors.to_h.dig(:environment, :debs, 1)
  end

  def test_rejects_empty_gems_element
    r = contract.call(valid_spec.merge(environment: { gems: ["rspec", ""] }))
    assert r.failure?
    assert r.errors.to_h.dig(:environment, :gems, 1)
  end

  def test_rejects_empty_mise_element
    r = contract.call(valid_spec.merge(environment: { mise: ["ruby@3.3", ""] }))
    assert r.failure?
    assert r.errors.to_h.dig(:environment, :mise, 1)
  end

  def test_deps_alias_payload_still_validates_byte_identically
    r = contract.call(valid_spec)
    assert r.success?, r.errors.to_h.inspect
    assert_equal ["git"], r.to_h.dig(:environment, :deps)
    assert_equal [], r.to_h.dig(:environment, :debs)
  end

  # --- environment.npm ----------------------------------------------------

  def test_accepts_npm_package_specs
    r = contract.call(valid_spec.merge(environment: valid_spec[:environment].merge(npm: ["cowsay", "left-pad@1.3.0"])))
    assert r.success?, r.errors.to_h.inspect
    assert_equal ["cowsay", "left-pad@1.3.0"], r.to_h.dig(:environment, :npm)
  end

  def test_rejects_empty_npm_element
    r = contract.call(valid_spec.merge(environment: valid_spec[:environment].merge(npm: ["cowsay", ""])))
    assert r.failure?
    assert r.errors.to_h.dig(:environment, :npm, 1)
  end

  # --- environment.files ---------------------------------------------------

  def test_accepts_files_with_absolute_paths
    files = [{ path: "/root/.pi/agent/extensions/local-inference.ts", content_b64: "Zm9v" }]
    r = contract.call(valid_spec.merge(environment: valid_spec[:environment].merge(files: files)))
    assert r.success?, r.errors.to_h.inspect
    assert_equal files, r.to_h.dig(:environment, :files)
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

  def test_rejects_empty_file_entry
    r = contract.call(valid_spec.merge(environment: valid_spec[:environment].merge(files: [{ path: "", content_b64: "" }])))
    assert r.failure?
    assert r.errors.to_h.dig(:environment, :files, 0)
  end

  def test_rejects_file_entry_missing_content_b64
    files = [{ path: "/root/.pi/agent/extensions/local-inference.ts" }]
    r = contract.call(valid_spec.merge(environment: valid_spec[:environment].merge(files: files)))
    assert r.failure?
    assert r.errors.to_h.dig(:environment, :files, 0, :content_b64)
  end

  def test_unknown_top_level_keys_are_dropped
    r = contract.call(valid_spec.merge(evil: "x"))
    assert r.success?
    refute r.to_h.key?(:evil)
  end

  # --- workspace / provenance (I16) -------------------------------------

  def test_workspace_dir_absolute_path_succeeds
    r = contract.call(valid_spec.merge(workspace: { dir: "/repo/worktree" }))
    assert r.success?, r.errors.to_h.inspect
    assert_equal "/repo/worktree", r.to_h.dig(:workspace, :dir)
  end

  def test_workspace_dir_relative_path_rejected
    r = contract.call(valid_spec.merge(workspace: { dir: "repo/worktree" }))
    assert r.failure?
    assert r.errors.to_h.dig(:workspace, :dir)
  end

  def test_workspace_dir_dot_dot_rejected
    r = contract.call(valid_spec.merge(workspace: { dir: "/repo/../etc" }))
    assert r.failure?
    assert r.errors.to_h.dig(:workspace, :dir)
  end

  def test_provenance_full_triple_succeeds
    r = contract.call(valid_spec.merge(provenance: { space: "s1", iteration: "I16", lane: "server" }))
    assert r.success?, r.errors.to_h.inspect
    assert_equal({ space: "s1", iteration: "I16", lane: "server" }, r.to_h[:provenance])
  end

  def test_provenance_missing_field_rejected
    r = contract.call(valid_spec.merge(provenance: { space: "s1", iteration: "I16" }))
    assert r.failure?
    assert r.errors.to_h.dig(:provenance, :lane)
  end

  def test_provenance_empty_field_rejected
    r = contract.call(valid_spec.merge(provenance: { space: "s1", iteration: "", lane: "server" }))
    assert r.failure?
    assert r.errors.to_h.dig(:provenance, :iteration)
  end

  def test_spec_without_workspace_or_provenance_still_valid
    r = contract.call(valid_spec)
    assert r.success?, r.errors.to_h.inspect
    refute r.to_h.key?(:workspace)
    refute r.to_h.key?(:provenance)
  end
end

# frozen_string_literal: true

# Minimal bootstrap for the sandbox_argv unit test — SandboxArgv.build is a pure
# function of (spec, image_tag), no DB/Redis needed. Mirrors ../env_image_test.rb's
# approach for the same reason.
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "space/server/jobs/executor/sandbox_argv"
require "minitest/autorun"

class SandboxArgvTest < Minitest::Test
  SandboxArgv = Space::Server::Jobs::Executor::SandboxArgv

  def spec(overrides = {})
    {
      "harness" => { "model" => "sonnet-5", "backend" => {} },
      "prompt" => "do the thing",
      "environment" => {}
    }.merge(overrides)
  end

  def test_no_workdir_flag_when_workspace_absent
    argv = SandboxArgv.build(spec, "img:abc123").value!
    refute_includes argv, "--workdir"
  end

  def test_workdir_flag_emitted_when_workspace_dir_present
    argv = SandboxArgv.build(spec("workspace" => { "dir" => "/repo/worktree" }), "img:abc123").value!
    assert_equal "/repo/worktree", argv[argv.index("--workdir") + 1]
  end

  def test_workdir_flag_precedes_image_tag
    argv = SandboxArgv.build(spec("workspace" => { "dir" => "/repo/worktree" }), "img:abc123").value!
    assert argv.index("--workdir") < argv.index("img:abc123"), "--workdir must precede the image tag"
  end

  def test_mount_handling_unchanged_alongside_workdir
    s = spec(
      "workspace" => { "dir" => "/repo/worktree" },
      "environment" => { "permissions" => { "mounts" => ["/data:/data:ro"] } }
    )
    argv = SandboxArgv.build(s, "img:abc123").value!
    assert_equal "/data:/data:ro", argv[argv.index("-v") + 1]
    assert_equal "/repo/worktree", argv[argv.index("--workdir") + 1]
  end

  # --- harness type branching (I17) ----------------------------------------

  def test_claude_argv_explicit_type_byte_identical_to_default
    argv = SandboxArgv.build(spec("harness" => { "type" => "claude", "model" => "sonnet-5", "backend" => {} }), "img:abc123").value!
    assert_equal ["claude", "-p", "do the thing", "--model", "sonnet-5",
                  "--output-format", "stream-json", "--verbose"], argv.last(8)
  end

  def test_pi_argv_shape
    s = spec("harness" => { "type" => "pi", "model" => "qwen3-27b-optiq", "backend" => {} })
    argv = SandboxArgv.build(s, "img:abc123").value!
    assert_equal ["pi", "-p", "--mode", "json", "--no-session", "--no-approve",
                  "--model", "qwen3-27b-optiq", "do the thing"], argv.last(9)
  end

  def test_pi_argv_appends_harness_args
    s = spec("harness" => { "type" => "pi", "model" => "qwen3-27b-optiq", "backend" => {}, "args" => ["--max-turns", "3"] })
    argv = SandboxArgv.build(s, "img:abc123").value!
    assert_equal ["--max-turns", "3"], argv.last(2)
  end

  def test_pi_gets_no_backend_env_injection
    s = spec("harness" => {
      "type" => "pi", "model" => "qwen3-27b-optiq",
      "backend" => { "base_url" => "https://gateway.example.com", "api_key_ref" => "op://vault/anthropic/key" }
    })
    argv = SandboxArgv.build(s, "img:abc123").value!
    refute argv.any? { |a| a.start_with?("ANTHROPIC_BASE_URL=") }, "pi must not receive ANTHROPIC_BASE_URL"
    refute_includes argv, "ANTHROPIC_API_KEY", "pi must not receive the bare -e ANTHROPIC_API_KEY name"
  end

  def test_pi_still_carries_declared_env_and_secrets
    s = spec(
      "harness" => { "type" => "pi", "model" => "qwen3-27b-optiq", "backend" => {} },
      "environment" => { "env" => { "FOO" => "bar" }, "secrets" => [{ "ref" => "op://vault/item", "name" => "TOKEN" }] }
    )
    argv = SandboxArgv.build(s, "img:abc123").value!
    assert_includes argv, "FOO=bar"
    assert_equal "-e", argv[argv.index("TOKEN") - 1]
  end

  def test_claude_still_gets_backend_env_injection
    s = spec("harness" => {
      "type" => "claude", "model" => "sonnet-5",
      "backend" => { "base_url" => "https://api.example.com", "api_key_ref" => "op://vault/anthropic/key" }
    })
    argv = SandboxArgv.build(s, "img:abc123").value!
    assert_includes argv, "ANTHROPIC_BASE_URL=https://api.example.com"
    assert_includes argv, "ANTHROPIC_API_KEY"
  end
end

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
end

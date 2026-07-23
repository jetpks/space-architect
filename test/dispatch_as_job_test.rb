# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "tmpdir"

# `architect dispatch --as-job` composition: ArchitectProject#dispatch_as_job builds
# a job spec from lane state and submits it via JobsClient#create, through the
# injectable jobs_client: seam (mirrors dispatch's run_creator: injection) — no live
# HTTP, no live server. Fixture setup mirrors DispatcherTest's git-template approach.
class DispatchAsJobTest < Space::ArchitectTest
  def self.template_space_dir
    @template_space_dir ||= begin
      root      = Dir.mktmpdir("dispatch-as-job-template")
      space_dir = File.join(root, "space")
      FileUtils.mkdir_p(space_dir)
      data = {
        "id" => "x", "title" => "Test Space", "status" => "active",
        "repos" => [], "notes" => [], "tickets" => [], "tags" => []
      }
      File.write(File.join(space_dir, "space.yaml"), YAML.dump(data))
      system("git", "-C", space_dir, "init", "-q")
      system("git", "-C", space_dir, "config", "user.email", "t@t")
      system("git", "-C", space_dir, "config", "user.name", "t")
      system("git", "-C", space_dir, "add", "space.yaml")
      system("git", "-C", space_dir, "commit", "-q", "-m", "init")

      repo_dir = File.join(space_dir, "repos", "my-repo")
      FileUtils.mkdir_p(repo_dir)
      system("git", "-C", repo_dir, "init", "-q")
      system("git", "-C", repo_dir, "config", "user.email", "t@t")
      system("git", "-C", repo_dir, "config", "user.name", "t")
      File.write(File.join(repo_dir, "f.txt"), "x")
      system("git", "-C", repo_dir, "add", "f.txt")
      system("git", "-C", repo_dir, "commit", "-q", "-m", "c0")
      space_dir
    end
  end

  def setup_space_with_worktree(root)
    space_dir = File.join(root, "space")
    FileUtils.cp_r(self.class.template_space_dir, space_dir)

    space   = Space::Core::Space.load(space_dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")

    build_dir = File.join(space_dir, "build", "I01-demo-A")
    FileUtils.mkdir_p(build_dir)
    File.write(File.join(build_dir, "prompt.md"), "PROMPT-MARKER-42\nrest\n")

    [space_dir, project, build_dir]
  end

  # A minimal stand-in for JobsClient: records the spec it was given and returns a
  # fixed id, so composition can be asserted without any HTTP layer at all.
  class FakeJobsClient
    attr_reader :spec

    def initialize(id: 99)
      @id = id
    end

    def create(spec)
      @spec = spec
      @id
    end
  end

  def test_dispatch_as_job_composes_spec_and_returns_job_id
    root = Dir.mktmpdir("dispatch-as-job-test")
    space_dir, project, build_dir = setup_space_with_worktree(root)
    fake = FakeJobsClient.new(id: 42)

    res = project.dispatch_as_job("demo", "A", host: "http://example.com", token: "tok",
      backend_url: "https://backend.example.com", job_model: "some/sandbox-model", jobs_client: fake)

    assert_equal 42, res[:job_id]
    spec = fake.spec

    assert_equal "PROMPT-MARKER-42\nrest\n", spec["prompt"]
    assert_equal File.join(space_dir, "build", "I01-demo-A", "wt"), spec["workspace"]["dir"]

    assert_equal ["git"], spec["environment"]["deps"]
    assert_equal true,    spec["environment"]["permissions"]["network"]
    mounts = spec["environment"]["permissions"]["mounts"]
    build_mount = "#{build_dir}:#{build_dir}"
    repo_mount  = "#{File.join(space_dir, 'repos', 'my-repo')}:#{File.join(space_dir, 'repos', 'my-repo')}"
    assert_includes mounts, build_mount
    assert_includes mounts, repo_mount

    assert_equal "unused-for-keyless-backends", spec["environment"]["env"]["ANTHROPIC_API_KEY"]
    refute spec["environment"].key?("secrets")

    assert_equal "claude",                     spec["harness"]["type"]
    assert_equal "https://backend.example.com", spec["harness"]["backend"]["base_url"]
    assert_equal "some/sandbox-model",         spec["harness"]["model"]

    args = spec["harness"]["args"]
    refute_includes args, "-p"
    refute_includes args, "--model"
    refute_includes args, "--output-format"
    refute_includes args, "--verbose"
    assert_includes args, "--permission-mode"
    assert_includes args, "--include-partial-messages"
    assert_includes args, "--max-turns"

    assert_equal({ "space" => "test-space", "iteration" => "demo", "lane" => "A" }, spec["provenance"])
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_as_job_with_job_model_sets_harness_model
    root = Dir.mktmpdir("dispatch-as-job-model-test")
    _space_dir, project, _build_dir = setup_space_with_worktree(root)
    fake = FakeJobsClient.new

    project.dispatch_as_job("demo", "A", host: "http://example.com", token: "tok",
      backend_url: "https://backend.example.com", job_model: "some/sandbox-model", jobs_client: fake)

    assert_equal "some/sandbox-model", fake.spec["harness"]["model"]
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_as_job_with_api_key_ref_uses_secrets_not_env_placeholder
    root = Dir.mktmpdir("dispatch-as-job-apikey-test")
    _space_dir, project, _build_dir = setup_space_with_worktree(root)
    fake = FakeJobsClient.new

    project.dispatch_as_job("demo", "A", host: "http://example.com", token: "tok",
      backend_url: "https://backend.example.com", job_model: "some/sandbox-model",
      api_key_ref: "op://vault/item/field", jobs_client: fake)

    spec = fake.spec
    refute spec["environment"]["env"].key?("ANTHROPIC_API_KEY")
    assert_equal [{ "ref" => "op://vault/item/field", "name" => "ANTHROPIC_API_KEY" }], spec["environment"]["secrets"]
    assert_equal "op://vault/item/field", spec["harness"]["backend"]["api_key_ref"]
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_as_job_records_job_id_and_dispatched_at_in_space_yaml
    root = Dir.mktmpdir("dispatch-as-job-bookkeeping-test")
    space_dir, project, _build_dir = setup_space_with_worktree(root)
    fake = FakeJobsClient.new(id: 123)
    fixed_now = Time.iso8601("2026-07-19T09:00:00-05:00")

    project.dispatch_as_job("demo", "A", host: "http://example.com", token: "tok",
      backend_url: "https://backend.example.com", job_model: "some/sandbox-model",
      jobs_client: fake, now: fixed_now)

    yaml = YAML.load_file(File.join(space_dir, "space.yaml"))
    lane = yaml.dig("project", "iterations", 0, "lanes", 0)
    assert_equal 123, lane["job_id"]
    assert_equal fixed_now.iso8601, lane["dispatched_at"]
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_as_job_rejects_non_claude_code_harness
    root = Dir.mktmpdir("dispatch-as-job-harness-guard-test")
    _space_dir, project, _build_dir = setup_space_with_worktree(root)
    fake = FakeJobsClient.new

    err = assert_raises(Space::Core::Error) do
      project.dispatch_as_job("demo", "A", host: "http://example.com", token: "tok",
        backend_url: "https://backend.example.com", harness: "pi", jobs_client: fake)
    end
    assert_match(/--as-job only supports the claude-code harness/, err.message)
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_as_job_raises_when_prompt_missing
    root = Dir.mktmpdir("dispatch-as-job-no-prompt-test")
    _space_dir, project, build_dir = setup_space_with_worktree(root)
    File.delete(File.join(build_dir, "prompt.md"))
    fake = FakeJobsClient.new

    err = assert_raises(Space::Core::Error) do
      project.dispatch_as_job("demo", "A", host: "http://example.com", token: "tok",
        backend_url: "https://backend.example.com", job_model: "some/sandbox-model", jobs_client: fake)
    end
    assert_match(/prompt\.md not found/, err.message)
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_as_job_requires_job_model
    root = Dir.mktmpdir("dispatch-as-job-no-model-test")
    _space_dir, project, _build_dir = setup_space_with_worktree(root)
    fake = FakeJobsClient.new

    err = assert_raises(Space::Core::Error) do
      project.dispatch_as_job("demo", "A", host: "http://example.com", token: "tok",
        backend_url: "https://backend.example.com", jobs_client: fake)
    end
    assert_match(/--job-model is required with --as-job/, err.message)
    assert_nil fake.spec, "the jobs client must not be called when --job-model is missing"
  ensure
    FileUtils.rm_rf(root)
  end
end

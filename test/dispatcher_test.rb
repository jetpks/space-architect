# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "tmpdir"

class DispatcherTest < Space::ArchitectTest
  FAKE_CLAUDE_SCRIPT = <<~RUBY
    #!/usr/bin/env ruby
    a = ARGV; c = Dir.pwd; s = $stdin.gets
    $stdout.puts "argv=" + a.inspect
    $stdout.puts "cwd=" + c.inspect
    $stdout.puts "stdin=" + (s || "").chomp
    $stdout.flush
    exit((ENV["FAKE_EXIT"] || "0").to_i)
  RUBY

  # Template space + my-repo (identical across every call): build the git fixtures once
  # per test run and cp_r them into each test's tmpdir instead of paying for `git
  # init`/`git commit` subprocess spawns every time.
  def self.template_space_dir
    @template_space_dir ||= begin
      root      = Dir.mktmpdir("dispatcher-template")
      space_dir = File.join(root, "space")
      FileUtils.mkdir_p(space_dir)
      data = {
        "id" => "x", "title" => "T", "status" => "active",
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

    fake = File.join(root, "fake_claude")
    File.write(fake, FAKE_CLAUDE_SCRIPT)
    File.chmod(0o755, fake)

    space   = Space::Core::Space.load(space_dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")

    build_dir = File.join(space_dir, "build", "I01-demo-A")
    FileUtils.mkdir_p(build_dir)
    File.write(File.join(build_dir, "prompt.md"), "PROMPT-MARKER-42\nrest\n")

    [space_dir, project, fake, build_dir]
  end

  def test_dispatch_writes_run_jsonl_with_policy_flags
    root = Dir.mktmpdir("dispatcher-test")
    _space_dir, project, fake, build_dir = setup_space_with_worktree(root)

    res = project.dispatch("demo", "A", claude_bin: fake)
    log = File.read(File.join(build_dir, "run.jsonl"))

    assert File.exist?(File.join(build_dir, "run.jsonl")), "run.jsonl must exist"
    refute log.strip.empty?, "run.jsonl must be non-empty"
    assert_includes log, "claude-sonnet-4-6"
    assert_includes log, "stream-json"
    assert_includes log, "acceptEdits"
    assert_includes log, "Bash(git commit"
    assert_includes log, "--max-turns"
    assert_includes log, "I01-demo-A/wt"
    assert_includes log, "PROMPT-MARKER-42"
    assert_equal 0, res[:exit_code]
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_reflects_nonzero_exit_code
    root = Dir.mktmpdir("dispatcher-test")
    _space_dir, project, fake, _build_dir = setup_space_with_worktree(root)

    with_env("FAKE_EXIT" => "7") do
      res = project.dispatch("demo", "A", claude_bin: fake)
      assert_equal 7, res[:exit_code]
    end
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_raises_error_when_prompt_missing
    root = Dir.mktmpdir("dispatcher-test")
    _space_dir, project, fake, build_dir = setup_space_with_worktree(root)
    File.delete(File.join(build_dir, "prompt.md"))

    assert_raises(Space::Core::Error) do
      project.dispatch("demo", "A", claude_bin: fake)
    end
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_records_dispatched_at_in_space_yaml
    root = Dir.mktmpdir("dispatcher-dispatched-at")
    space_dir, project, fake, _build_dir = setup_space_with_worktree(root)

    fixed_now = Time.iso8601("2026-06-15T09:30:00-05:00")
    project.dispatch("demo", "A", claude_bin: fake, now: fixed_now)

    yaml = YAML.load_file(File.join(space_dir, "space.yaml"))
    lane = yaml.dig("project", "iterations", 0, "lanes", 0)
    assert_equal fixed_now.iso8601, lane["dispatched_at"]
    assert Time.iso8601(lane["dispatched_at"]), "dispatched_at must parse as ISO8601"
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_detach_records_dispatched_at_in_space_yaml
    root = Dir.mktmpdir("dispatcher-dispatched-at-detach")
    space_dir, project, fake, _build_dir = setup_space_with_worktree(root)

    fixed_now = Time.iso8601("2026-06-15T10:00:00-05:00")
    project.dispatch("demo", "A", claude_bin: fake, detach: true, now: fixed_now)

    yaml = YAML.load_file(File.join(space_dir, "space.yaml"))
    lane = yaml.dig("project", "iterations", 0, "lanes", 0)
    assert_equal fixed_now.iso8601, lane["dispatched_at"]
  ensure
    sleep 0.1
    FileUtils.rm_rf(root)
  end

  def test_dispatch_overwrites_dispatched_at_on_redispatch
    root = Dir.mktmpdir("dispatcher-dispatched-at-overwrite")
    space_dir, project, fake, _build_dir = setup_space_with_worktree(root)

    first_now = Time.iso8601("2026-06-15T09:00:00-05:00")
    project.dispatch("demo", "A", claude_bin: fake, now: first_now)

    second_now = Time.iso8601("2026-06-15T11:00:00-05:00")
    project.dispatch("demo", "A", claude_bin: fake, now: second_now)

    yaml = YAML.load_file(File.join(space_dir, "space.yaml"))
    lane = yaml.dig("project", "iterations", 0, "lanes", 0)
    assert_equal second_now.iso8601, lane["dispatched_at"]
  ensure
    FileUtils.rm_rf(root)
  end

  FAKE_DETACH_SCRIPT = <<~RUBY
    #!/usr/bin/env ruby
    $stdout.puts "pid=\#{Process.pid}"
    $stdout.flush
    sleep 0.05
    $stdout.puts "done"
    $stdout.flush
    exit 0
  RUBY

  def test_dispatcher_run_detached_returns_integer_pid
    root = Dir.mktmpdir("dispatcher-test")
    fake_bin = File.join(root, "fake_detach")
    File.write(fake_bin, FAKE_DETACH_SCRIPT)
    File.chmod(0o755, fake_bin)

    wt_dir  = File.join(root, "wt")
    FileUtils.mkdir_p(wt_dir)
    prompt  = File.join(root, "prompt.md")
    run_log = File.join(root, "run.jsonl")
    File.write(prompt, "test prompt\n")

    dispatcher = Space::Architect::Dispatcher.new(claude_bin: fake_bin)
    pid = dispatcher.run_detached(prompt_path: prompt, run_log_path: run_log, chdir: wt_dir)

    assert_instance_of Integer, pid
    assert pid > 0
    assert_equal pid, Process.getpgid(pid), "child must be its own pgroup leader"
  ensure
    sleep 0.1
    FileUtils.rm_rf(root)
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "tmpdir"

class DispatchDetachTest < Space::ArchitectTest
  # Fake builder: writes its PID line immediately, sleeps to give parent a window to inspect,
  # then writes "done" and exits. stdout is redirected to run.jsonl by run_detached.
  FAKE_DETACH_BUILDER = <<~RUBY
    #!/usr/bin/env ruby
    $stdout.puts "child_pid=\#{Process.pid}"
    $stdout.flush
    sleep 0.3
    $stdout.puts "done"
    $stdout.flush
    exit 0
  RUBY

  def setup_detach_space(root)
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

    fake_bin = File.join(root, "fake_detach_builder")
    File.write(fake_bin, FAKE_DETACH_BUILDER)
    File.chmod(0o755, fake_bin)

    space   = Space::Core::Space.load(space_dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")

    [space_dir, project, fake_bin]
  end

  def setup_lane(space_dir, project, fake_bin, lane_name)
    project.worktree_add("my-repo", "demo", lane_name)
    build_dir = File.join(space_dir, "build", "I01-demo-#{lane_name}")
    FileUtils.mkdir_p(build_dir)
    File.write(File.join(build_dir, "prompt.md"), "DETACH-PROMPT-#{lane_name}\n")
    build_dir
  end

  # (a) run_detached returns a PID without blocking for the builder's full lifetime
  def test_run_detached_returns_immediately_without_blocking
    root = Dir.mktmpdir("detach-test")
    space_dir, project, fake_bin = setup_detach_space(root)
    setup_lane(space_dir, project, fake_bin, "A")

    t0 = Time.now
    res = project.dispatch("demo", "A", claude_bin: fake_bin, detach: true)
    elapsed = Time.now - t0
    pid = res[:pid]

    assert_instance_of Integer, pid
    assert pid > 0
    # builder sleeps 0.3s — returning in < 0.1s proves we did not wait for it
    assert elapsed < 0.1, "run_detached blocked (took #{elapsed.round(3)}s; builder sleeps 0.3s)"
  ensure
    Process.waitpid(pid, Process::WNOHANG) rescue nil
    sleep 0.35 # let child finish so it doesn't outlive the tmpdir removal
    FileUtils.rm_rf(root)
  end

  # (b) child is its own process-group leader
  def test_run_detached_child_is_own_pgroup_leader
    root = Dir.mktmpdir("detach-test")
    space_dir, project, fake_bin = setup_detach_space(root)
    setup_lane(space_dir, project, fake_bin, "B")

    res = project.dispatch("demo", "B", claude_bin: fake_bin, detach: true)
    pid = res[:pid]

    # Child is sleeping 0.3s — safe to check pgroup while it's alive
    pgid = Process.getpgid(pid)
    assert_equal pid, pgid, "child must be its own process-group leader"
  ensure
    sleep 0.35
    FileUtils.rm_rf(root)
  end

  # (c) detached child completes its work after run_detached has already returned
  def test_run_detached_child_completes_work_after_launcher_returns
    root = Dir.mktmpdir("detach-test")
    space_dir, project, fake_bin = setup_detach_space(root)
    build_dir = setup_lane(space_dir, project, fake_bin, "C")

    res = project.dispatch("demo", "C", claude_bin: fake_bin, detach: true)
    pid = res[:pid]
    run_log = File.join(build_dir, "run.jsonl")

    # Give the child a moment to write its pid line, but NOT long enough for "done"
    sleep 0.05
    content_before = File.exist?(run_log) ? File.read(run_log) : ""
    refute_includes content_before, "done",
      "run.jsonl should not contain 'done' immediately after run_detached returns (child still sleeping)"

    # Wait for child to complete (it sleeps 0.3s then writes "done")
    deadline = Time.now + 5
    sleep 0.05 until (File.exist?(run_log) && File.read(run_log).include?("done")) || Time.now > deadline

    assert File.exist?(run_log), "run.jsonl must exist after child completes"
    assert_includes File.read(run_log), "done", "child must write completion marker after run_detached returns"
  ensure
    FileUtils.rm_rf(root)
  end

  # Return hash shape: detach: true → { pid:, run_log:, report:, worktree: } (no exit_code)
  def test_dispatch_detach_true_returns_pid_hash_without_exit_code
    root = Dir.mktmpdir("detach-test")
    space_dir, project, fake_bin = setup_detach_space(root)
    setup_lane(space_dir, project, fake_bin, "D")

    res = project.dispatch("demo", "D", claude_bin: fake_bin, detach: true)

    assert res.key?(:pid),       "result must include :pid"
    assert res.key?(:run_log),   "result must include :run_log"
    assert res.key?(:report),    "result must include :report"
    assert res.key?(:worktree),  "result must include :worktree"
    refute res.key?(:exit_code), "detach result must NOT include :exit_code"
  ensure
    sleep 0.35
    FileUtils.rm_rf(root)
  end

  # Existing blocking path is unchanged when detach: false (default)
  def test_dispatch_detach_false_returns_exit_code_hash
    root = Dir.mktmpdir("detach-test")
    space_dir, project, fake_bin = setup_detach_space(root)
    # Use a fast-exiting stub for the blocking path
    fast_bin = File.join(root, "fast_builder")
    File.write(fast_bin, "#!/usr/bin/env ruby\n$stdout.puts 'ok'\nexit 0\n")
    File.chmod(0o755, fast_bin)
    setup_lane(space_dir, project, fast_bin, "E")

    res = project.dispatch("demo", "E", claude_bin: fast_bin, detach: false)

    assert res.key?(:exit_code), "blocking result must include :exit_code"
    assert_equal 0, res[:exit_code]
    refute res.key?(:pid), "blocking result must NOT include :pid"
  ensure
    FileUtils.rm_rf(root)
  end
end

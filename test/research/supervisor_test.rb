# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "json"
require "tmpdir"

class SupervisorTest < Space::ArchitectTest
  STUB_BIN = File.expand_path("../../test/research/stub_claude", __dir__)

  def setup_space(root)
    space_dir = File.join(root, "space")
    FileUtils.mkdir_p(space_dir)
    data = {
      "id" => "test", "title" => "T", "status" => "active",
      "repos" => [], "notes" => [], "tickets" => [], "tags" => []
    }
    File.write(File.join(space_dir, "space.yaml"), YAML.dump(data))
    system("git", "-C", space_dir, "init", "-q")
    system("git", "-C", space_dir, "config", "user.email", "t@t")
    system("git", "-C", space_dir, "config", "user.name", "t")
    system("git", "-C", space_dir, "add", "space.yaml")
    system("git", "-C", space_dir, "commit", "-q", "-m", "init")
    Space::Core::Space.load(space_dir)
  end

  def write_prompt(space, name, content = "Research question about #{name}")
    prompt_path = Pathname.new(space.path).join("#{name}.prompt.md")
    prompt_path.write(content)
    prompt_path
  end

  def wait_for_completion(space, timeout: 10)
    registry_path = space.path.join("build", "research", "registry.yaml")
    deadline = Time.now + timeout
    loop do
      break if Time.now > deadline
      sleep 0.1
      next unless registry_path.exist?

      runs = YAML.safe_load(registry_path.read, aliases: false) || []
      all_done = runs.all? do |r|
        next false unless File.exist?(r["run_log_path"])

        content = File.read(r["run_log_path"])
        events  = content.lines.filter_map { |l| JSON.parse(l.chomp) rescue nil }
        events.any? { |e| e["type"] == "result" }
      end
      break if all_done && !runs.empty?
    end
  end

  # ── dispatch is non-blocking ──────────────────────────────────────────────

  def test_dispatch_returns_immediately_with_pids
    root = Dir.mktmpdir("sup-test")
    space = setup_space(root)
    p1 = write_prompt(space, "01-topic-one")
    p2 = write_prompt(space, "02-topic-two")

    supervisor = Space::Architect::Research::Supervisor.new(space: space, bin: STUB_BIN)

    t0 = Time.now
    runs = supervisor.dispatch([p1.to_s, p2.to_s])
    elapsed = Time.now - t0

    assert_equal 2, runs.size
    runs.each do |run|
      assert_instance_of Integer, run.pid
      assert run.pid > 0
    end
    assert elapsed < 1.0, "dispatch must be non-blocking (took #{elapsed.round(3)}s)"
  ensure
    sleep 0.1
    FileUtils.rm_rf(root)
  end

  # ── dispatch creates correct directory structure ──────────────────────────

  def test_dispatch_creates_dirs_and_copies_prompt
    root = Dir.mktmpdir("sup-test")
    space = setup_space(root)
    p1 = write_prompt(space, "01-async-api", "PROMPT_CONTENT_HERE")

    supervisor = Space::Architect::Research::Supervisor.new(space: space, bin: STUB_BIN)
    runs = supervisor.dispatch([p1.to_s])
    run = runs.first

    assert_equal "01-async-api", run.id
    assert File.exist?(run.prompt_path.to_s), "prompt.md must be copied"
    assert_includes File.read(run.prompt_path.to_s), "PROMPT_CONTENT_HERE"
    assert_equal run.dir.join("run.jsonl"), run.run_log_path
    assert_equal run.dir.join("report.md"), run.report_path
  ensure
    sleep 0.1
    FileUtils.rm_rf(root)
  end

  # ── dispatch registers in registry.yaml ──────────────────────────────────

  def test_dispatch_registers_in_registry
    root = Dir.mktmpdir("sup-test")
    space = setup_space(root)
    p1 = write_prompt(space, "01-topic")

    supervisor = Space::Architect::Research::Supervisor.new(space: space, bin: STUB_BIN)
    runs = supervisor.dispatch([p1.to_s])

    registry_path = space.path.join("build", "research", "registry.yaml")
    assert File.exist?(registry_path.to_s), "registry.yaml must be created"

    entries = YAML.safe_load(File.read(registry_path.to_s), aliases: false)
    assert_equal 1, entries.size
    assert_equal "01-topic", entries.first["id"]
    assert_equal runs.first.pid, entries.first["pid"]
  ensure
    sleep 0.1
    FileUtils.rm_rf(root)
  end

  # ── wait extracts report.md from result event ─────────────────────────────

  def test_wait_extracts_report_from_result_event
    root = Dir.mktmpdir("sup-test")
    space = setup_space(root)
    p1 = write_prompt(space, "01-research")

    supervisor = Space::Architect::Research::Supervisor.new(space: space, bin: STUB_BIN)
    runs = supervisor.dispatch([p1.to_s])

    out = StringIO.new
    result = supervisor.wait(level: 1, out: out)

    run = runs.first
    assert File.exist?(run.report_path.to_s), "report.md must be written after wait"
    assert_includes File.read(run.report_path.to_s), "Final research summary here."
    assert_equal :ok, result
  ensure
    FileUtils.rm_rf(root)
  end

  # ── wait exits :ok when all succeed, :failed when any fail ───────────────

  def test_wait_returns_ok_when_all_succeed
    root = Dir.mktmpdir("sup-test")
    space = setup_space(root)
    p1 = write_prompt(space, "01-a")

    supervisor = Space::Architect::Research::Supervisor.new(space: space, bin: STUB_BIN)
    supervisor.dispatch([p1.to_s])

    result = supervisor.wait(level: 0, out: StringIO.new)
    assert_equal :ok, result
  ensure
    FileUtils.rm_rf(root)
  end

  def test_wait_returns_failed_when_lane_errors
    root = Dir.mktmpdir("sup-test")
    space = setup_space(root)
    p1 = write_prompt(space, "01-err")

    with_env("STUB_CLAUDE_FIXTURE" => "error") do
      supervisor = Space::Architect::Research::Supervisor.new(space: space, bin: STUB_BIN)
      supervisor.dispatch([p1.to_s])

      result = supervisor.wait(level: 0, out: StringIO.new)
      assert_equal :failed, result
    end
  ensure
    FileUtils.rm_rf(root)
  end

  # ── wait is quiet at L0 ───────────────────────────────────────────────────

  def test_wait_quiet_emits_nothing
    root = Dir.mktmpdir("sup-test")
    space = setup_space(root)
    p1 = write_prompt(space, "01-quiet")

    supervisor = Space::Architect::Research::Supervisor.new(space: space, bin: STUB_BIN)
    supervisor.dispatch([p1.to_s])

    out = StringIO.new
    supervisor.wait(quiet: true, out: out)
    assert out.string.empty?, "quiet must suppress all output: #{out.string.inspect}"
  ensure
    FileUtils.rm_rf(root)
  end

  # ── status classifies runs ────────────────────────────────────────────────

  def test_status_classifies_complete_run
    root = Dir.mktmpdir("sup-test")
    space = setup_space(root)
    p1 = write_prompt(space, "01-status")

    supervisor = Space::Architect::Research::Supervisor.new(space: space, bin: STUB_BIN)
    supervisor.dispatch([p1.to_s])

    # wait for the child to finish
    wait_for_completion(space)

    entries = supervisor.status
    run_entry = entries.find { |e| e[:run].id == "01-status" }
    assert_equal :complete, run_entry[:state]
  ensure
    FileUtils.rm_rf(root)
  end

  # ── run.jsonl appears in expected location ────────────────────────────────

  def test_run_jsonl_written_by_child
    root = Dir.mktmpdir("sup-test")
    space = setup_space(root)
    p1 = write_prompt(space, "01-jsonl")

    supervisor = Space::Architect::Research::Supervisor.new(space: space, bin: STUB_BIN)
    runs = supervisor.dispatch([p1.to_s])
    run = runs.first

    wait_for_completion(space)

    assert File.exist?(run.run_log_path.to_s), "run.jsonl must exist after child completes"
    events = File.readlines(run.run_log_path.to_s).map { |l| JSON.parse(l.chomp) }
    assert events.any? { |e| e["type"] == "result" }, "run.jsonl must contain result event"
  ensure
    FileUtils.rm_rf(root)
  end
end

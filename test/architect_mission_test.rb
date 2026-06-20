# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "yaml"

class ArchitectMissionTest < SpaceArchitectTest
  def create_real_space(dir)
    FileUtils.mkdir_p(File.join(dir, "architecture"))
    FileUtils.mkdir_p(File.join(dir, "repos"))
    FileUtils.mkdir_p(File.join(dir, "tmp"))

    data = {
      "version" => 1, "id" => "test-space", "title" => "Test", "status" => "active",
      "created_at" => "2026-06-19T00:00:00Z", "updated_at" => "2026-06-19T00:00:00Z",
      "repos" => [], "notes" => [], "tickets" => [], "tags" => []
    }
    File.write(File.join(dir, "space.yaml"), YAML.dump(data))

    system("git", "-C", dir, "init", "-q", "-b", "main", exception: false) ||
      system("git", "-C", dir, "init", "-q")
    system("git", "-C", dir, "config", "user.name", "Test Builder")
    system("git", "-C", dir, "config", "user.email", "test@example.com")
    system("git", "-C", dir, "add", "space.yaml")
    system("git", "-C", dir, "commit", "-q", "-m", "init")

    SpaceArchitect::Space.load(dir)
  end

  def create_real_repo(space_dir, name)
    repo_dir = File.join(space_dir, "repos", name)
    FileUtils.mkdir_p(repo_dir)
    system("git", "-C", repo_dir, "init", "-q", "-b", "main", exception: false) ||
      system("git", "-C", repo_dir, "init", "-q")
    system("git", "-C", repo_dir, "config", "user.name", "Test Builder")
    system("git", "-C", repo_dir, "config", "user.email", "test@example.com")
    File.write(File.join(repo_dir, "README.md"), "# #{name}\n")
    system("git", "-C", repo_dir, "add", "README.md")
    system("git", "-C", repo_dir, "commit", "-q", "-m", "init #{name}")
    repo_dir
  end

  # G3: worktree_add records I-prefixed iteration_id worktree path and creates
  #     an I-prefixed branch (e.g. wt/I01-my-slice-lane-a, lane/I01-my-slice-lane-a)
  def test_worktree_add_records_ordinal_prefixed_path_and_branch
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    result = mission.worktree_add("my-repo", "my-slice", "lane-a")

    assert_match %r{wt/I01-my-slice-lane-a\z}, result[:worktree].to_s
    assert_path_exists result[:worktree].to_s

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lane = yml.dig("architect", "iterations", 0, "lanes", 0)
    assert_equal "tmp/architect/wt/I01-my-slice-lane-a", lane["worktree"]

    branch_ref = File.join(dir, "repos", "my-repo", ".git", "refs", "heads", "lane", "I01-my-slice-lane-a")
    assert_path_exists branch_ref, "expected branch lane/I01-my-slice-lane-a to exist in git"
  ensure
    FileUtils.rm_rf(dir)
  end

  # G4: verify looks for the scratch report at I-prefixed iteration_id path
  #     (tmp/architect/I01-my-slice-lane-a.report.md) — bare-name path is not found
  def test_verify_finds_ordinal_prefixed_scratch_report
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    mission.freeze!("my-slice")
    mission.worktree_add("my-repo", "my-slice", "lane-a")

    FileUtils.mkdir_p(File.join(dir, "tmp", "architect"))
    File.write(File.join(dir, "tmp", "architect", "I01-my-slice-lane-a.report.md"),
      "# Report\nSTATUS: COMPLETE\n")

    results = mission.verify("my-slice")
    lane_result = results.find { |r| r[:lane] == "lane-a" }
    assert lane_result[:checks][:report_exists],
      "expected (c) report_exists to be true with I-prefixed report at I01-my-slice-lane-a.report.md"
  ensure
    FileUtils.rm_rf(dir)
  end

  # G5: worktree_remove prefers the recorded bare-name worktree path (back-compat
  #     for lanes written before the ordinal-id convention)
  def test_worktree_remove_uses_recorded_bare_name_worktree
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    mission.freeze!("my-slice")

    bare_wt_rel = "tmp/architect/wt/my-slice-lane-a"
    bare_wt_path = File.join(dir, bare_wt_rel)
    repo_path = File.join(dir, "repos", "my-repo")
    FileUtils.mkdir_p(File.dirname(bare_wt_path))
    system("git", "-C", repo_path, "worktree", "add", bare_wt_path, "-b", "lane/my-slice-lane-a", "HEAD")
    assert_path_exists bare_wt_path

    sha, = Open3.capture3("git", "-C", repo_path, "rev-parse", "HEAD")
    iteration_entry = space.data.dig("architect", "iterations").find { |s| s["name"] == "my-slice" }
    iteration_entry["lanes"] = [{
      "name" => "lane-a",
      "repo" => "my-repo",
      "base_sha" => sha.strip,
      "worktree" => bare_wt_rel,
      "integration_branch" => nil
    }]
    space.save

    mission.worktree_remove("my-slice", "lane-a")

    refute_path_exists bare_wt_path, "expected bare-name worktree dir to be removed"
  ensure
    FileUtils.rm_rf(dir)
  end
end

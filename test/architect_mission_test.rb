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

    assert_match %r{build/I01-my-slice-lane-a/wt\z}, result[:worktree].to_s
    assert_path_exists result[:worktree].to_s

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lane = yml.dig("architect", "iterations", 0, "lanes", 0)
    assert_equal "build/I01-my-slice-lane-a/wt", lane["worktree"]

    branch_ref = File.join(dir, "repos", "my-repo", ".git", "refs", "heads", "lane", "I01-my-slice-lane-a")
    assert_path_exists branch_ref, "expected branch lane/I01-my-slice-lane-a to exist in git"
  ensure
    FileUtils.rm_rf(dir)
  end

  # G4: verify looks for the scratch report at I-prefixed iteration_id path
  #     (build/I01-my-slice-lane-a/report.md) — bare-name path is not found
  def test_verify_finds_ordinal_prefixed_scratch_report
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    mission.freeze!("my-slice")
    mission.worktree_add("my-repo", "my-slice", "lane-a")

    FileUtils.mkdir_p(File.join(dir, "build", "I01-my-slice-lane-a"))
    File.write(File.join(dir, "build", "I01-my-slice-lane-a", "report.md"),
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

  # AC2: worktree_add persists harness and model on the lane entry
  def test_worktree_add_persists_harness_and_model
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    mission.worktree_add("my-repo", "my-slice", "lane-a",
                         harness: "opencode",
                         model: "fireworks-ai/accounts/fireworks/models/glm-5p2")

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lane = yml.dig("architect", "iterations", 0, "lanes", 0)

    assert_equal "opencode", lane["harness"]
    assert_equal "fireworks-ai/accounts/fireworks/models/glm-5p2", lane["model"]
    # Pre-existing keys must still be present
    assert_equal "lane-a",   lane["name"]
    assert_equal "my-repo",  lane["repo"]
    assert        lane["base_sha"]
    assert_match %r{build/I01-my-slice-lane-a/wt}, lane["worktree"]
    assert_nil    lane["integration_branch"]
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC5: worktree_add raises footgun error for opencode without a valid model
  def test_worktree_add_footgun_raises_for_opencode_without_model
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")

    # nil model raises, and error names --model
    err = assert_raises(SpaceArchitect::Error) do
      mission.worktree_add("my-repo", "my-slice", "lane-bad", harness: "opencode")
    end
    assert_match(/--model/, err.message)

    # claude default model also raises
    assert_raises(SpaceArchitect::Error) do
      mission.worktree_add("my-repo", "my-slice", "lane-bad",
                           harness: "opencode",
                           model: SpaceArchitect::Harness::CLAUDE_DEFAULT_MODEL)
    end
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC7: plain worktree_add persists variant: false (backward-compat)
  def test_worktree_add_records_variant_false_by_default
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    mission.worktree_add("my-repo", "my-slice", "lane-a")

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lane = yml.dig("architect", "iterations", 0, "lanes", 0)

    assert_equal false, lane["variant"]
    assert_equal "lane-a", lane["name"]
    assert_equal "my-repo", lane["repo"]
    assert lane["base_sha"]
    assert lane["worktree"]
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2: variant_add creates v01/v02 with variant: true and correct harness/model
  def test_variant_add_creates_named_lanes_with_variant_true
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    mission.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lanes = yml.dig("architect", "iterations", 0, "lanes")

    assert_equal 2, lanes.length

    v01 = lanes.find { |l| l["name"] == "v01" }
    v02 = lanes.find { |l| l["name"] == "v02" }

    refute_nil v01, "expected v01 lane"
    refute_nil v02, "expected v02 lane"

    assert_equal true, v01["variant"]
    assert_equal "claude-code", v01["harness"]
    assert_nil   v01["model"]
    assert_equal "my-repo", v01["repo"]
    assert v01["base_sha"]
    assert v01["worktree"]
    assert_nil v01["integration_branch"]

    assert_equal true, v02["variant"]
    assert_equal "opencode", v02["harness"]
    assert_equal "fireworks-ai/accounts/fireworks/models/glm-5p2", v02["model"]
    assert_equal "my-repo", v02["repo"]
    assert v02["base_sha"]
    assert v02["worktree"]
    assert_nil v02["integration_branch"]

    repo_path = File.join(dir, "repos", "my-repo")
    assert_path_exists File.join(repo_path, ".git", "refs", "heads", "lane", "I01-my-slice-v01")
    assert_path_exists File.join(repo_path, ".git", "refs", "heads", "lane", "I01-my-slice-v02")
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC3: variant_add fans out a byte-identical prompt to each variant's build dir
  def test_variant_add_fans_out_byte_identical_prompt
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    prompt_src = File.join(dir, "prompt_src.md")
    File.binwrite(prompt_src, "# Frozen Prompt\nWith special bytes: \xC3\xA9\n")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    mission.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]],
                        prompt: prompt_src)

    src_bytes = File.binread(prompt_src)
    v01_bytes = File.binread(File.join(dir, "build", "I01-my-slice-v01", "prompt.md"))
    v02_bytes = File.binread(File.join(dir, "build", "I01-my-slice-v02", "prompt.md"))

    assert_equal src_bytes, v01_bytes, "v01 prompt.md must be byte-identical to source"
    assert_equal src_bytes, v02_bytes, "v02 prompt.md must be byte-identical to source"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4: a second variant_add call appends with continued ordinals (v03)
  def test_variant_add_appends_ordinals_across_calls
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    mission.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])
    mission.variant_add("my-repo", "my-slice", [["claude-code", nil]])

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lanes = yml.dig("architect", "iterations", 0, "lanes")

    assert_equal 3, lanes.length
    names = lanes.map { |l| l["name"] }
    assert_includes names, "v01"
    assert_includes names, "v02"
    assert_includes names, "v03"
    lanes.each { |l| assert_equal true, l["variant"] }
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC5: footgun fires for opencode+nil model; no lane or worktree left behind
  def test_variant_add_inherits_footgun_guard
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")

    err = assert_raises(SpaceArchitect::Error) do
      mission.variant_add("my-repo", "my-slice", [["opencode", nil]])
    end
    assert_match(/--model/, err.message)

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lanes = yml.dig("architect", "iterations", 0, "lanes") || []
    assert_empty lanes, "no lane entry should be persisted after footgun raise"

    repo_path = File.join(dir, "repos", "my-repo")
    v01_branch = File.join(repo_path, ".git", "refs", "heads", "lane", "I01-my-slice-v01")
    refute_path_exists v01_branch, "no branch should be created after footgun raise"

    v01_wt = File.join(dir, "build", "I01-my-slice-v01", "wt")
    refute_path_exists v01_wt, "no worktree should be created after footgun raise"
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_rendered_scaffolds_name_real_commands_not_space_architect
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")

    architect_md = File.read(File.join(dir, "architecture", "ARCHITECT.md"))
    iteration_md = File.read(File.join(dir, "architecture", "I01-my-slice.md"))

    refute_match(/space architect/, architect_md)
    refute_match(/space architect/, iteration_md)
    assert_match(/architect new/, architect_md)
    assert_match(/architect freeze/, iteration_md)
    assert_match(/architect verify/, iteration_md)
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2: variant_promote records the winner on the iteration and discarded flags
  #      on each variant lane, preserving all pre-existing keys
  def test_variant_promote_records_winner_and_discarded_flags
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    mission.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])

    result = mission.variant_promote("my-slice", "v02")

    assert_equal "v02", result[:winner]
    assert_equal ["v01"], result[:discarded]

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    iter = yml.dig("architect", "iterations", 0)

    assert_equal "v02", iter["winner"]
    # pre-existing iteration keys preserved
    assert_equal "my-slice", iter["name"]
    assert_equal 1, iter["ordinal"]
    assert_equal "architecture/I01-my-slice.md", iter["file"]
    assert_nil iter["freeze_sha"]
    assert_equal "pending", iter["verdict"]
    assert iter["lanes"].is_a?(Array)

    v01 = iter["lanes"].find { |l| l["name"] == "v01" }
    v02 = iter["lanes"].find { |l| l["name"] == "v02" }

    assert_equal true,  v01["discarded"]
    assert_equal false, v02["discarded"]
    # pre-existing lane keys preserved on both
    [v01, v02].each do |l|
      assert l["name"]
      assert_equal "my-repo", l["repo"]
      assert l["base_sha"]
      assert l["worktree"]
      assert_nil l["integration_branch"]
      assert l["harness"]
      assert l.key?("model")
      assert_equal true, l["variant"]
    end
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC3: validate-before-mutate — bad winner raises and writes nothing
  def test_variant_promote_validates_before_mutate
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    mission.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])
    # also add a non-variant lane to test (b)
    mission.worktree_add("my-repo", "my-slice", "lane-a")

    # (a) non-existent lane name
    err = assert_raises(SpaceArchitect::Error) do
      mission.variant_promote("my-slice", "v99")
    end
    assert_match(/v99/, err.message)

    # (b) name of a non-variant lane
    err = assert_raises(SpaceArchitect::Error) do
      mission.variant_promote("my-slice", "lane-a")
    end
    assert_match(/lane-a/, err.message)

    # After both raises: no winner key, no discarded keys on variant lanes
    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    iter = yml.dig("architect", "iterations", 0)

    refute iter.key?("winner"), "no winner key should be written after a raise"

    variant_lanes = (iter["lanes"] || []).select { |l| l["variant"] == true }
    variant_lanes.each do |l|
      refute l.key?("discarded"), "no discarded key should be written on variant lane after a raise"
    end
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4: idempotent re-promote — second call reassigns winner and recomputes flags
  def test_variant_promote_is_idempotent_repromote
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    mission.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])

    mission.variant_promote("my-slice", "v02")
    mission.variant_promote("my-slice", "v01")

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    iter = yml.dig("architect", "iterations", 0)

    assert_equal "v01", iter["winner"]

    v01 = iter["lanes"].find { |l| l["name"] == "v01" }
    v02 = iter["lanes"].find { |l| l["name"] == "v02" }

    assert_equal false, v01["discarded"]
    assert_equal true,  v02["discarded"]
    # no duplicate keys — YAML round-trip would not duplicate, but verify count
    assert_equal 1, iter["lanes"].count { |l| l["name"] == "v01" }
    assert_equal 1, iter["lanes"].count { |l| l["name"] == "v02" }
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC6: promote raises on a no-variant iteration and writes nothing
  def test_variant_promote_raises_on_no_variant_iteration
    dir = Dir.mktmpdir("architect-mission-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("my-slice")
    mission.worktree_add("my-repo", "my-slice", "lane-a")

    err = assert_raises(SpaceArchitect::Error) do
      mission.variant_promote("my-slice", "lane-a")
    end
    assert_match(/no variant/, err.message)

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    iter = yml.dig("architect", "iterations", 0)

    refute iter.key?("winner"), "no winner key should be written on a no-variant iteration"
    lane = iter["lanes"].find { |l| l["name"] == "lane-a" }
    refute lane.key?("discarded"), "no discarded key should be written on a non-variant lane"
  ensure
    FileUtils.rm_rf(dir)
  end
end

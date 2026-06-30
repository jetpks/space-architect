# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "yaml"
require "async/http/mock"
require "async/http/client"
require "protocol/http/response"

class ArchitectProjectTest < Space::ArchitectTest
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

    Space::Core::Space.load(dir)
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
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    result = project.worktree_add("my-repo", "my-slice", "lane-a")

    assert_match %r{build/I01-my-slice-lane-a/wt\z}, result[:worktree].to_s
    assert_path_exists result[:worktree].to_s

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lane = yml.dig("project", "iterations", 0, "lanes", 0)
    assert_equal "build/I01-my-slice-lane-a/wt", lane["worktree"]

    branch_ref = File.join(dir, "repos", "my-repo", ".git", "refs", "heads", "lane", "I01-my-slice-lane-a")
    assert_path_exists branch_ref, "expected branch lane/I01-my-slice-lane-a to exist in git"
  ensure
    FileUtils.rm_rf(dir)
  end

  # G4: verify looks for the scratch report at I-prefixed iteration_id path
  #     (build/I01-my-slice-lane-a/report.md) — bare-name path is not found
  def test_verify_finds_ordinal_prefixed_scratch_report
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    FileUtils.mkdir_p(File.join(dir, "build", "I01-my-slice-lane-a"))
    File.write(File.join(dir, "build", "I01-my-slice-lane-a", "report.md"),
      "# Report\nSTATUS: COMPLETE\n")

    results = project.verify("my-slice")
    lane_result = results.find { |r| r[:lane] == "lane-a" }
    assert lane_result[:checks][:report_exists],
      "expected (c) report_exists to be true with I-prefixed report at I01-my-slice-lane-a.report.md"
  ensure
    FileUtils.rm_rf(dir)
  end

  # G5: worktree_remove prefers the recorded bare-name worktree path (back-compat
  #     for lanes written before the ordinal-id convention)
  def test_worktree_remove_uses_recorded_bare_name_worktree
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")

    bare_wt_rel = "tmp/architect/wt/my-slice-lane-a"
    bare_wt_path = File.join(dir, bare_wt_rel)
    repo_path = File.join(dir, "repos", "my-repo")
    FileUtils.mkdir_p(File.dirname(bare_wt_path))
    system("git", "-C", repo_path, "worktree", "add", bare_wt_path, "-b", "lane/my-slice-lane-a", "HEAD", out: File::NULL, err: File::NULL)
    assert_path_exists bare_wt_path

    sha, = Open3.capture3("git", "-C", repo_path, "rev-parse", "HEAD")
    iteration_entry = space.data.dig("project", "iterations").find { |s| s["name"] == "my-slice" }
    iteration_entry["lanes"] = [{
      "name" => "lane-a",
      "repo" => "my-repo",
      "base_sha" => sha.strip,
      "worktree" => bare_wt_rel,
      "integration_branch" => nil
    }]
    space.save

    project.worktree_remove("my-slice", "lane-a")

    refute_path_exists bare_wt_path, "expected bare-name worktree dir to be removed"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2: worktree_add persists harness and model on the lane entry
  def test_worktree_add_persists_harness_and_model
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a",
                         harness: "opencode",
                         model: "fireworks-ai/accounts/fireworks/models/glm-5p2")

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lane = yml.dig("project", "iterations", 0, "lanes", 0)

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
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    # nil model raises, and error names --model
    err = assert_raises(Space::Core::Error) do
      project.worktree_add("my-repo", "my-slice", "lane-bad", harness: "opencode")
    end
    assert_match(/--model/, err.message)

    # claude default model also raises
    assert_raises(Space::Core::Error) do
      project.worktree_add("my-repo", "my-slice", "lane-bad",
                           harness: "opencode",
                           model: Space::Architect::Harness::CLAUDE_DEFAULT_MODEL)
    end
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC7: plain worktree_add persists variant: false (backward-compat)
  def test_worktree_add_records_variant_false_by_default
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lane = yml.dig("project", "iterations", 0, "lanes", 0)

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
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lanes = yml.dig("project", "iterations", 0, "lanes")

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
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    prompt_src = File.join(dir, "prompt_src.md")
    File.binwrite(prompt_src, "# Frozen Prompt\nWith special bytes: \xC3\xA9\n")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.variant_add("my-repo", "my-slice",
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
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])
    project.variant_add("my-repo", "my-slice", [["claude-code", nil]])

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lanes = yml.dig("project", "iterations", 0, "lanes")

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
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    err = assert_raises(Space::Core::Error) do
      project.variant_add("my-repo", "my-slice", [["opencode", nil]])
    end
    assert_match(/--model/, err.message)

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lanes = yml.dig("project", "iterations", 0, "lanes") || []
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
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

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
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])

    result = project.variant_promote("my-slice", "v02")

    assert_equal "v02", result[:winner]
    assert_equal ["v01"], result[:discarded]

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    iter = yml.dig("project", "iterations", 0)

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
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])
    # also add a non-variant lane to test (b)
    project.worktree_add("my-repo", "my-slice", "lane-a")

    # (a) non-existent lane name
    err = assert_raises(Space::Core::Error) do
      project.variant_promote("my-slice", "v99")
    end
    assert_match(/v99/, err.message)

    # (b) name of a non-variant lane
    err = assert_raises(Space::Core::Error) do
      project.variant_promote("my-slice", "lane-a")
    end
    assert_match(/lane-a/, err.message)

    # After both raises: no winner key, no discarded keys on variant lanes
    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    iter = yml.dig("project", "iterations", 0)

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
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])

    project.variant_promote("my-slice", "v02")
    project.variant_promote("my-slice", "v01")

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    iter = yml.dig("project", "iterations", 0)

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

  # ── I05: effort persistence and footgun ──────────────────────────────────

  # AC5(a): effort "high" persisted on lane entry; all pre-existing keys preserved
  def test_worktree_add_persists_effort_when_set
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-e",
                         harness: "opencode",
                         model: "fireworks-ai/accounts/fireworks/models/glm-5p2",
                         effort: "high")

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lane = yml.dig("project", "iterations", 0, "lanes", 0)

    assert_equal "high", lane["effort"]
    # pre-existing keys preserved
    assert_equal "lane-e",   lane["name"]
    assert_equal "my-repo",  lane["repo"]
    assert        lane["base_sha"]
    assert_match %r{build/I01-my-slice-lane-e/wt}, lane["worktree"]
    assert_nil    lane["integration_branch"]
    assert_equal "opencode", lane["harness"]
    assert_equal "fireworks-ai/accounts/fireworks/models/glm-5p2", lane["model"]
    assert_equal false, lane["variant"]
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC5(b): no effort kwarg → NO "effort" key in lane entry at all
  def test_worktree_add_no_effort_key_when_not_set
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-f",
                         harness: "opencode",
                         model: "fireworks-ai/accounts/fireworks/models/glm-5p2")

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lane = yml.dig("project", "iterations", 0, "lanes", 0)

    refute lane.key?("effort"), "effort key must be absent when not set"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4(a): effort on a claude-code lane raises and writes nothing
  def test_worktree_add_footgun_raises_for_effort_on_claude_code
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    err = assert_raises(Space::Core::Error) do
      project.worktree_add("my-repo", "my-slice", "lane-bad",
                           harness: "claude-code", effort: "high")
    end
    assert_match(/opencode-only/, err.message)
    assert_match(/reasoningEffort/, err.message)

    # Nothing persisted after the raise
    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lanes = yml.dig("project", "iterations", 0, "lanes") || []
    assert_empty lanes, "no lane should be written after footgun raise"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC6: promote raises on a no-variant iteration and writes nothing
  def test_variant_promote_raises_on_no_variant_iteration
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    err = assert_raises(Space::Core::Error) do
      project.variant_promote("my-slice", "lane-a")
    end
    assert_match(/no variant/, err.message)

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    iter = yml.dig("project", "iterations", 0)

    refute iter.key?("winner"), "no winner key should be written on a no-variant iteration"
    lane = iter["lanes"].find { |l| l["name"] == "lane-a" }
    refute lane.key?("discarded"), "no discarded key should be written on a non-variant lane"
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── I06: variant compare + worktree_remove preservation ───────────────────

  # AC1: variant_compare returns a structured hash with one descriptor per
  #      variant lane (non-variant lanes excluded), status derived from winner
  def test_variant_compare_returns_structured_descriptor_with_status
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")
    project.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])
    # non-variant lane must be EXCLUDED from the compare result
    project.worktree_add("my-repo", "my-slice", "lane-a")
    project.variant_promote("my-slice", "v02")

    result = project.variant_compare("my-slice")

    assert_equal "v02", result[:winner]
    assert_match(/\A[0-9a-f]{40}\z/, result[:freeze_sha])
    assert_equal 2, result[:variants].length, "non-variant lanes must be excluded"

    v01 = result[:variants].find { |v| v[:name] == "v01" }
    v02 = result[:variants].find { |v| v[:name] == "v02" }

    assert_equal "v01",               v01[:name]
    assert_equal "claude-code",       v01[:harness]
    assert_nil                       v01[:model]
    assert_nil                       v01[:effort]
    assert v01[:base_sha]
    assert_nil                       v01[:integration_branch]
    assert_equal "discarded",         v01[:status]

    assert_equal "v02",               v02[:name]
    assert_equal "opencode",          v02[:harness]
    assert_equal "fireworks-ai/accounts/fireworks/models/glm-5p2", v02[:model]
    assert_nil                       v02[:effort]
    assert v02[:base_sha]
    assert_nil                       v02[:integration_branch]
    assert_equal "winner",            v02[:status]
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC1: status is "pending" for every variant lane when winner is nil
  def test_variant_compare_returns_pending_when_no_winner
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])

    result = project.variant_compare("my-slice")

    assert_nil result[:winner]
    assert_equal 2, result[:variants].length
    assert_equal ["pending", "pending"], result[:variants].map { |v| v[:status] }
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC1: harness defaults to "claude-code" when the record's value is nil
  def test_variant_compare_defaults_nil_harness_to_claude_code
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.variant_add("my-repo", "my-slice", [["claude-code", nil]])

    # Simulate a record with nil harness (e.g. from older code)
    space.data.dig("project", "iterations").find { |s| s["name"] == "my-slice" }["lanes"][0]["harness"] = nil

    result = project.variant_compare("my-slice")
    assert_equal "claude-code", result[:variants].first[:harness]
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2: variant_compare on an iteration with no variant lanes raises and writes nothing
  def test_variant_compare_raises_on_no_variant_iteration
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    err = assert_raises(Space::Core::Error) do
      project.variant_compare("my-slice")
    end
    assert_match(/no variant set — nothing to compare/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4: worktree_remove preserves the lane record (worktree → nil) and
  #      leaves winner / discarded flags and all other fields byte-identical
  def test_worktree_remove_preserves_lane_record_after_promote
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.variant_add("my-repo", "my-slice",
                        [["claude-code", nil], ["opencode", "fireworks-ai/accounts/fireworks/models/glm-5p2"]])
    project.variant_promote("my-slice", "v02")

    # Snapshot the lane record before removal
    yml_before = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    iter_before = yml_before.dig("project", "iterations", 0)
    lane_before = iter_before["lanes"].find { |l| l["name"] == "v01" }
    wt_path_before = lane_before["worktree"]
    refute_nil wt_path_before

    project.worktree_remove("my-slice", "v01")

    yml_after = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    iter_after = yml_after.dig("project", "iterations", 0)
    lane_after = iter_after["lanes"].find { |l| l["name"] == "v01" }

    # (a) winner unchanged
    assert_equal "v02", iter_after["winner"]

    # (b) every variant lane's discarded flag unchanged
    iter_after["lanes"].select { |l| l["variant"] }.each do |l|
      expected = (l["name"] != "v02")
      assert_equal expected, l["discarded"], "discarded flag for #{l['name']} must be unchanged"
    end

    # (c) removed lane is STILL PRESENT with worktree == nil, all other fields byte-identical
    refute_nil lane_after, "removed lane must still be present in the record"
    assert_nil lane_after["worktree"], "worktree must be nil after removal"
    expected = lane_before.reject { |k, _| k == "worktree" }
    actual = lane_after.reject { |k, _| k == "worktree" }
    assert_equal expected, actual, "all fields except worktree must be byte-identical after removal"

    # (d) the physical worktree directory no longer exists
    refute_path_exists File.join(dir, wt_path_before)
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── section / evidence / brief / gate / integrate (CLI-absorbs-persistence) ──

  # write_section! lands the body below the frozen boundary, preserves every other
  # section, and commits with the canonical per-section message.
  def test_write_section_replaces_body_and_commits_canonical_message
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    res = project.write_section!("my-slice", "specification", body: "- Objective — wire the seam (BRIEF §3.1)")
    assert res[:committed]
    assert_match(/\A[0-9a-f]{40}\z/, res[:sha])

    text = File.read(File.join(dir, "architecture", "I01-my-slice.md"))
    assert_match(/wire the seam \(BRIEF §3\.1\)/, text)
    # other sections survive
    assert_match(/^## Acceptance Criteria/, text)
    assert_match(/^## Builder Prompt/, text)
    assert_match(/^## Verdict/, text)

    msg, = Open3.capture3("git", "-C", dir, "log", "-1", "--format=%s")
    assert_equal "I01: specification", msg.strip
  ensure
    FileUtils.rm_rf(dir)
  end

  # write_section! refuses a frozen section once the iteration is frozen.
  def test_write_section_refuses_frozen_section_after_freeze
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")

    err = assert_raises(Space::Core::Error) do
      project.write_section!("my-slice", "specification", body: "tampered")
    end
    assert_match(/frozen/i, err.message)

    # but a below-the-boundary section (verdict) is still writable after freeze
    res = project.write_section!("my-slice", "verdict", body: "CONTINUE — diff vs BRIEF §1 faithful")
    assert res[:committed]
  ensure
    FileUtils.rm_rf(dir)
  end

  # write_section! --append stacks per-lane ### subsections under Builder Prompt.
  def test_write_section_append_stacks_lane_subsections
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    project.write_section!("my-slice", "prompt", body: "prompt for A", append: true, lane: "lane-a")
    project.write_section!("my-slice", "prompt", body: "prompt for B", append: true, lane: "lane-b")

    text = File.read(File.join(dir, "architecture", "I01-my-slice.md"))
    bp = text[/## Builder Prompt.*?(?=## Builder Report)/m]
    assert_match(/### lane-a\n\nprompt for A/, bp)
    assert_match(/### lane-b\n\nprompt for B/, bp)
  ensure
    FileUtils.rm_rf(dir)
  end

  # transcribe_evidence! copies the scratch report VERBATIM — even when it contains
  # its own "## " headings and markdown tables — and surfaces the STATUS line.
  def test_transcribe_evidence_is_verbatim_even_with_hashes_and_tables
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    report = "## Results\n\n| AC | result |\n|----|--------|\n| G0 | 222/0/0 |\n\nSTATUS: COMPLETE\n"
    FileUtils.mkdir_p(File.join(dir, "build", "I01-my-slice-lane-a"))
    File.write(File.join(dir, "build", "I01-my-slice-lane-a", "report.md"), report)

    res = project.transcribe_evidence!("my-slice", lane: "lane-a")
    assert_equal "STATUS: COMPLETE", res[:status_line]

    text = File.read(File.join(dir, "architecture", "I01-my-slice.md"))
    # the verbatim block (including its own ## heading + table) is present under Builder Report
    assert_includes text, "## Results"
    assert_includes text, "| G0 | 222/0/0 |"
    # and the Verdict section that follows is intact (parser wasn't fooled by the report's ## )
    assert_match(/^## Verdict/, text)
  ensure
    FileUtils.rm_rf(dir)
  end

  # brief_new! scaffolds architecture/BRIEF.md with numbered §sections and commits it;
  # a second call without --force is refused.
  def test_brief_new_scaffolds_numbered_sections_and_guards
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    path = project.brief_new!

    assert_path_exists path.to_s
    brief = File.read(path)
    assert_match(/^## 1\. Goal & non-goals/, brief)
    assert_match(/^## 7\. Definition of done/, brief)
    assert_match(/BRIEF §N/, brief)

    err = assert_raises(Space::Core::Error) { project.brief_new! }
    assert_match(/already exists/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # worktree_add --touch records touch_set, which makes verify's (d) in-bounds check
  # meaningful: an out-of-bounds write reports in_bounds == false.
  def test_worktree_add_touch_set_drives_in_bounds_check
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a", touch: ["allowed/**"])

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    assert_equal ["allowed/**"], yml.dig("project", "iterations", 0, "lanes", 0, "touch_set")

    wt = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    File.write(File.join(wt, "out-of-bounds.rb"), "x = 1\n")

    checks = project.verify("my-slice").first[:checks]
    assert_equal false, checks[:in_bounds], "an out-of-bounds write must report in_bounds == false"
  ensure
    FileUtils.rm_rf(dir)
  end

  # merge_lane! refuses a lane whose worktree carries builder commits (tamper).
  def test_merge_lane_refuses_builder_commits
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    wt = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    File.write(File.join(wt, "work.rb"), "x = 1\n")
    system("git", "-C", wt, "add", "work.rb")
    system("git", "-C", wt, "commit", "-q", "-m", "builder commit")

    err = assert_raises(Space::Core::Error) { project.merge_lane!("my-slice", "lane-a") }
    assert_match(/builder commits/i, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # merge_lane! integrates a clean lane: commits the working tree on the lane branch
  # and merges --no-ff into project/<slug>, recording the integration branch.
  def test_merge_lane_integrates_clean_lane
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    wt = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    File.write(File.join(wt, "feature.rb"), "def feature; end\n")

    r = project.merge_lane!("my-slice", "lane-a")
    assert_match(/\Aproject\//, r[:integration_branch], "integration branch must be project/<slug>")
    assert_equal false, r[:gates_run]

    repo = File.join(dir, "repos", "my-repo")
    branch_parts = r[:integration_branch].split("/")
    assert_path_exists File.join(repo, ".git", "refs", "heads", *branch_parts)
    log, = Open3.capture3("git", "-C", repo, "log", r[:integration_branch], "--format=%s")
    assert_match(/Merge lane\/I01-my-slice-lane-a/, log)

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    assert_equal r[:integration_branch], yml.dig("project", "iterations", 0, "lanes", 0, "integration_branch")
    assert_equal r[:integration_branch], yml.dig("project", "integration_branch")
  ensure
    FileUtils.rm_rf(dir)
  end

  # merge_lane! accumulates all iterations on one stable project/<slug> branch.
  # Two consecutive merge_lane! calls must land on the identical branch.
  def test_merge_lane_project_integration_accumulates
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    project.new_iteration!("s1")
    project.freeze!("s1")
    project.worktree_add("my-repo", "s1", "lane-a")
    File.write(File.join(dir, "build", "I01-s1-lane-a", "wt", "feature1.rb"), "def f1; end\n")
    r1 = project.merge_lane!("s1", "lane-a")

    project.new_iteration!("s2")
    project.freeze!("s2")
    project.worktree_add("my-repo", "s2", "lane-b")
    File.write(File.join(dir, "build", "I02-s2-lane-b", "wt", "feature2.rb"), "def f2; end\n")
    r2 = project.merge_lane!("s2", "lane-b")

    assert_match(/\Aproject\//, r1[:integration_branch])
    assert_equal r1[:integration_branch], r2[:integration_branch], "both iterations must accumulate on the same branch"

    repo = File.join(dir, "repos", "my-repo")
    log, = Open3.capture3("git", "-C", repo, "log", r1[:integration_branch], "--format=%s")
    assert_match(/Merge lane\/I01-s1-lane-a/, log)
    assert_match(/Merge lane\/I02-s2-lane-b/, log)
  ensure
    FileUtils.rm_rf(dir)
  end

  # land generates PR body and command for each integrated repo; raises if nothing integrated.
  def test_land_generates_pr_command
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    err = assert_raises(Space::Core::Error) { project.land }
    assert_match(/nothing integrated yet/, err.message)

    project.new_iteration!("my-slice")
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")
    File.write(File.join(dir, "build", "I01-my-slice-lane-a", "wt", "feature.rb"), "def feature; end\n")
    project.merge_lane!("my-slice", "lane-a")

    results = project.land
    assert_equal 1, results.size
    r = results.first
    assert_equal "my-repo", r[:repo]
    assert_match(/\Aproject\//, r[:integration_branch])
    assert_match(/gh pr create --base main/, r[:command])
    assert_match(/--head project\//, r[:command])
    assert_path_exists r[:body_file]
    body = File.read(r[:body_file])
    assert_match(/my-slice/, body)
  ensure
    FileUtils.rm_rf(dir)
  end

  # run_gates reads the frozen gates block, executes each command, and attaches
  # a mechanical :status/:reason from GateEvaluator. Raw :stdout/:stderr/:exit_code
  # are preserved unchanged; verdict tokens (PASS/FAIL/INVALID) must NOT appear in
  # the raw output fields — :status is a Ruby symbol, kept separate from text output.
  def test_run_gates_returns_raw_output_without_verdict_tokens
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    # Inject a real gate into the scaffold's gates block, then freeze
    slice = File.join(dir, "architecture", "I01-my-slice.md")
    text = File.read(slice)
    gate_yaml = <<~YAML
      - id: hello-gate
        ac: AC1
        cmd: echo hello-gate
        expect:
          exit_code: 0
    YAML
    text = text.sub(/^```gates\n.*?^```/m, "```gates\n#{gate_yaml}```")
    File.write(slice, text)
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    results = project.run_gates("my-slice", lane: "lane-a")
    assert_equal 1, results.length
    assert_equal "echo hello-gate", results[0][:cmd]
    assert_match(/hello-gate/, results[0][:stdout])
    assert_equal 0, results[0][:exit_code]

    # GateEvaluator attaches :status/:reason; raw text fields carry no verdict tokens
    assert_equal :pass, results[0][:status]
    assert_empty results[0][:reason]
    blob = results.map { |r| "#{r[:cmd]} #{r[:stdout]} #{r[:stderr]}" }.join(" ")
    refute_match(/\b(PASS|FAIL|INVALID)\b/, blob, "raw output fields must carry no verdict tokens")
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_run_gates_fail_on_nonzero_exit
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    slice = File.join(dir, "architecture", "I01-my-slice.md")
    text = File.read(slice)
    gate_yaml = <<~YAML
      - id: failing-gate
        ac: AC1
        cmd: sh -c 'exit 2'
        expect:
          exit_code: 0
    YAML
    text = text.sub(/^```gates\n.*?^```/m, "```gates\n#{gate_yaml}```")
    File.write(slice, text)
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    results = project.run_gates("my-slice", lane: "lane-a")
    assert_equal :fail, results[0][:status]
    assert_match(/exit_code/, results[0][:reason])
    assert_equal 2, results[0][:exit_code]
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── dispatch: push_host guards and URL derivation ──────────────────────────

  def setup_dispatch_space(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")
    build_dir = File.join(dir, "build", "I01-demo-A")
    FileUtils.mkdir_p(build_dir)
    File.write(File.join(build_dir, "prompt.md"), "test prompt\n")
    [space, project, build_dir]
  end

  def fake_claude_bin(dir)
    bin = File.join(dir, "fake_claude_dispatch")
    File.write(bin, <<~RUBY)
      #!/usr/bin/env ruby
      $stdout.puts "ok"
      $stdout.flush
      exit 0
    RUBY
    File.chmod(0o755, bin)
    bin
  end

  # AC4(a): push_host + push_token creates a run via the injected creator and
  # derives push_url = "<host>/runs/<id>/ingest".
  def test_dispatch_push_host_derives_push_url_from_created_run_id
    dir = Dir.mktmpdir("architect-project-dispatch")
    _space, project, _build = setup_dispatch_space(dir)
    bin = fake_claude_bin(dir)

    fake_creator = Object.new
    def fake_creator.create = 99

    mock_endpoint = Async::HTTP::Mock::Endpoint.new

    Sync do
      server_task = Async do
        mock_endpoint.run do |request|
          request.body&.read
          Protocol::HTTP::Response[200, [], nil]
        end
      end

      push_client = Async::HTTP::Client.new(mock_endpoint)

      result = project.dispatch("demo", "A",
                                push_host:    "https://architect.example.com",
                                push_token:   "my-ingest-token",
                                run_creator:  fake_creator,
                                push_client:  push_client,
                                claude_bin:   bin)

      assert_equal 99, result[:created_run_id]
      assert_equal "https://architect.example.com/runs/99/ingest", result[:push_url]

      push_client.close
      server_task.stop
    end
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4(b): push_host without push_token raises before the builder is spawned.
  def test_dispatch_push_host_without_token_raises_before_builder
    dir = Dir.mktmpdir("architect-project-dispatch")
    _space, project, _build = setup_dispatch_space(dir)

    assert_raises(Space::Core::Error) do
      project.dispatch("demo", "A", push_host: "http://example.com")
    end
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4(c): push_host together with push_url raises.
  def test_dispatch_push_host_and_push_url_together_raises
    dir = Dir.mktmpdir("architect-project-dispatch")
    _space, project, _build = setup_dispatch_space(dir)

    assert_raises(Space::Core::Error) do
      project.dispatch("demo", "A",
                       push_host:  "http://example.com",
                       push_url:   "http://example.com/runs/1/ingest",
                       push_token: "tok")
    end
  ensure
    FileUtils.rm_rf(dir)
  end

  # --detach is mutually exclusive with the push options (push tees the live
  # pipe in-process, which a detached builder has no one to read).
  def test_dispatch_detach_with_push_url_raises
    dir = Dir.mktmpdir("architect-project-dispatch")
    _space, project, _build = setup_dispatch_space(dir)

    assert_raises(Space::Core::Error) do
      project.dispatch("demo", "A", detach: true,
                       push_url: "http://example.com/runs/1/ingest")
    end
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_dispatch_detach_with_push_host_raises
    dir = Dir.mktmpdir("architect-project-dispatch")
    _space, project, _build = setup_dispatch_space(dir)

    assert_raises(Space::Core::Error) do
      project.dispatch("demo", "A", detach: true,
                       push_host: "http://example.com", push_token: "tok")
    end
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4(d): neither push_host nor push_url — no run created, dispatch unchanged.
  def test_dispatch_without_push_options_does_not_invoke_creator
    dir = Dir.mktmpdir("architect-project-dispatch")
    _space, project, _build = setup_dispatch_space(dir)
    bin = fake_claude_bin(dir)

    sentinel = Object.new
    def sentinel.create = raise("run_creator must not be called when no push_host is set")

    result = project.dispatch("demo", "A", run_creator: sentinel, claude_bin: bin)

    refute result[:created_run_id], "no run should be created without push_host"
    refute result[:push_url],       "no push_url should be set without push options"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2 (I04): rendered ARCHITECT.md carries the Backlog section and
  # FNM_PATHNAME: a single * in a touch_set glob must not cross /
  # lib/*.rb accepts lib/foo.rb but rejects lib/sub/bar.rb.
  def test_bounds_glob_single_star_does_not_cross_slash
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a", touch: ["lib/*.rb"])

    wt = File.join(dir, "build", "I01-my-slice-lane-a", "wt")

    # Stage lib/foo.rb — in-bounds (lib/*.rb matches lib/foo.rb with FNM_PATHNAME)
    FileUtils.mkdir_p(File.join(wt, "lib"))
    File.write(File.join(wt, "lib", "foo.rb"), "# ok\n")
    system("git", "-C", wt, "add", "lib/foo.rb")
    checks = project.verify("my-slice").first[:checks]
    assert_equal true, checks[:in_bounds], "lib/*.rb must accept lib/foo.rb"

    # Stage lib/sub/bar.rb — out-of-bounds (single * must not cross / with FNM_PATHNAME)
    FileUtils.mkdir_p(File.join(wt, "lib", "sub"))
    File.write(File.join(wt, "lib", "sub", "bar.rb"), "# out\n")
    system("git", "-C", wt, "add", "lib/sub/bar.rb")
    checks = project.verify("my-slice").first[:checks]
    assert_equal false, checks[:in_bounds], "lib/*.rb must not accept lib/sub/bar.rb with FNM_PATHNAME"
  ensure
    FileUtils.rm_rf(dir)
  end

  # ordinals-at-spec-time doctrine, pinned through the real init! render path.
  def test_rendered_architect_md_contains_backlog_section_and_ordinals_at_spec_time_doctrine
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    architect_md = File.read(File.join(dir, "architecture", "ARCHITECT.md"))

    assert_match(/Backlog/, architect_md)
    assert_match(/spec.time/i, architect_md)
  ensure
    FileUtils.rm_rf(dir)
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "yaml"
require "json"
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
    yaml = YAML.dump(data)
    File.write(File.join(dir, "space.yaml"), yaml)
    FileUtils.cp_r(File.join(Space::GitFixtureTemplate.space_dir(yaml), ".git"), dir)

    Space::Core::Space.load(dir)
  end

  def create_real_repo(space_dir, name)
    repo_dir = File.join(space_dir, "repos", name)
    FileUtils.mkdir_p(repo_dir)
    FileUtils.cp_r(File.join(Space::GitFixtureTemplate.repo_dir, ".git"), repo_dir)
    File.write(File.join(repo_dir, "README.md"), "# #{name}\n")
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

  # acceptance-criteria is now a first-class section target:
  # (a) well-formed AC + gates block writes and commits; (b) malformed gates block raises
  # before writing/committing.
  def test_write_section_authors_acceptance_criteria
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    # (a) well-formed AC with a gates block writes and commits
    ac_body = <<~BODY
      The seam holds end-to-end.

      ```gates
      - id: g1
        ac: AC1
        cmd: "true"
        expect:
          exit_code: 0
      ```
    BODY

    res = project.write_section!("my-slice", "acceptance-criteria", body: ac_body)
    assert res[:committed]
    assert_match(/\A[0-9a-f]{40}\z/, res[:sha])

    text = File.read(File.join(dir, "architecture", "I01-my-slice.md"))
    assert_match(/The seam holds end-to-end/, text)
    assert_match(/^## Acceptance Criteria/, text)

    msg, = Open3.capture3("git", "-C", dir, "log", "-1", "--format=%s")
    assert_equal "I01: acceptance criteria", msg.strip

    # (b) malformed gates block raises before writing/committing
    text_before = File.read(File.join(dir, "architecture", "I01-my-slice.md"))
    head_before, = Open3.capture3("git", "-C", dir, "rev-parse", "HEAD")

    err = assert_raises(Space::Core::Error) do
      project.write_section!("my-slice", "acceptance-criteria", body: <<~BAD)
        Malformed gates follow.

        ```gates
        - id: g1
          ac: AC1
          cmd: "true"
          expect: {}
        ```
      BAD
    end
    assert_match(/ill-formed/i, err.message)

    assert_equal text_before, File.read(File.join(dir, "architecture", "I01-my-slice.md"))
    head_after, = Open3.capture3("git", "-C", dir, "rev-parse", "HEAD")
    assert_equal head_before.strip, head_after.strip
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

  # git collapses an untracked file inside a brand-new directory to the directory
  # path (`?? allowed/`) unless `git status` is asked for `-uall`; that collapsed
  # path never matches a file glob, so a legitimate new file in a new directory
  # must still report in_bounds == true.
  def test_in_bounds_accepts_new_file_in_new_dir
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a", touch: ["allowed/*.rb"])

    wt = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    FileUtils.mkdir_p(File.join(wt, "allowed"))
    File.write(File.join(wt, "allowed", "foo.rb"), "x = 1\n")

    checks = project.verify("my-slice").first[:checks]
    assert_equal true, checks[:in_bounds], "a new file in a new dir matching the touch glob must be in-bounds"
  ensure
    FileUtils.rm_rf(dir)
  end

  # FNM_PATHNAME makes a trailing `dir/**` behave like a single `*` (direct children
  # only), so modifying a pre-existing tracked file ≥2 dirs deep false-negatived the
  # in-bounds check. The fix also checks the `dir/**/*` form, whose whole-component
  # `**/` DOES cross `/` under FNM_PATHNAME — a sibling directory must still reject.
  def test_in_bounds_deep_modify_under_dir_glob
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    repo_dir = create_real_repo(dir, "my-repo")

    FileUtils.mkdir_p(File.join(repo_dir, "roles", "cilium", "tasks"))
    File.write(File.join(repo_dir, "roles", "cilium", "tasks", "Debian.yaml"), "orig: true\n")
    system("git", "-C", repo_dir, "add", "roles/cilium/tasks/Debian.yaml")
    system("git", "-C", repo_dir, "commit", "-q", "-m", "seed deep file")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a", touch: ["roles/cilium/**"])

    wt = File.join(dir, "build", "I01-my-slice-lane-a", "wt")

    # Modify the pre-existing deep tracked file — in-bounds.
    File.write(File.join(wt, "roles", "cilium", "tasks", "Debian.yaml"), "orig: false\n")
    system("git", "-C", wt, "add", "roles/cilium/tasks/Debian.yaml")
    checks = project.verify("my-slice").first[:checks]
    assert_equal true, checks[:in_bounds], "roles/cilium/** must accept a modified roles/cilium/tasks/Debian.yaml"

    # Stage a sibling dir's file — out-of-bounds detection must not be loosened.
    FileUtils.mkdir_p(File.join(wt, "roles", "kubeadm"))
    File.write(File.join(wt, "roles", "kubeadm", "x.yaml"), "x: 1\n")
    system("git", "-C", wt, "add", "roles/kubeadm/x.yaml")
    checks = project.verify("my-slice").first[:checks]
    assert_equal false, checks[:in_bounds], "roles/cilium/** must not accept roles/kubeadm/x.yaml"
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

  # AC1 + AC3: conductor mode accepts canonical conductor commits and still rejects
  # non-canonical commits (tamper detection). Also covers CLI-flag override (AC3):
  # passing commit_mode: "conductor" to project.verify without space.yaml commit_mode.
  def test_verify_conductor_mode_accepts_canonical_conductor_commit
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
    system("git", "-C", wt, "add", "work.rb", out: File::NULL, err: File::NULL)
    system("git", "-C", wt, "commit", "-q", "-m", "I01-my-slice-lane-a: builder output")

    # AC3: CLI-flag override — no space.yaml commit_mode, param wins → canonical commit passes
    results = project.verify("my-slice", commit_mode: "conductor")
    lane_checks = results.find { |r| r[:lane] == "lane-a" }[:checks]
    assert_equal true, lane_checks[:no_builder_commits],
      "canonical conductor commit must not be flagged in conductor mode (CLI override)"

    # AC1: space.yaml commit_mode: "conductor" — no CLI param → canonical commit passes
    space.data["project"]["commit_mode"] = "conductor"
    results2 = project.verify("my-slice")
    lane_checks2 = results2.find { |r| r[:lane] == "lane-a" }[:checks]
    assert_equal true, lane_checks2[:no_builder_commits],
      "canonical conductor commit must not be flagged when commit_mode: conductor in space.yaml"

    # Tamper detection: non-canonical commit IS still a builder commit even in conductor mode
    File.write(File.join(wt, "work2.rb"), "y = 2\n")
    system("git", "-C", wt, "add", "work2.rb", out: File::NULL, err: File::NULL)
    system("git", "-C", wt, "commit", "-q", "-m", "rogue builder commit")
    results3 = project.verify("my-slice", commit_mode: "conductor")
    lane_checks3 = results3.find { |r| r[:lane] == "lane-a" }[:checks]
    assert_equal false, lane_checks3[:no_builder_commits],
      "non-canonical commit must still be flagged in conductor mode (tamper detection preserved)"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2: default (nil/strict) commit_mode rejects any commit beyond base_sha,
  # including commits that happen to have a canonical conductor message shape.
  def test_verify_strict_default_rejects_non_canonical_commit
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
    system("git", "-C", wt, "add", "work.rb", out: File::NULL, err: File::NULL)
    # Even a canonically-shaped message is rejected in strict mode
    system("git", "-C", wt, "commit", "-q", "-m", "I01-my-slice-lane-a: builder output")

    results = project.verify("my-slice")
    lane_checks = results.find { |r| r[:lane] == "lane-a" }[:checks]
    assert_equal false, lane_checks[:no_builder_commits],
      "strict mode (default) must reject any commit beyond base_sha"
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

  def test_run_gates_timeout_kills_long_running_command
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    slice = File.join(dir, "architecture", "I01-my-slice.md")
    text = File.read(slice)
    gate_yaml = <<~YAML
      - id: timeout-gate
        ac: AC3
        cmd: sleep 30
        timeout: 0.2
        expect:
          exit_code: 0
    YAML
    text = text.sub(/^```gates\n.*?^```/m, "```gates\n#{gate_yaml}```")
    File.write(slice, text)
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    t0 = Time.now
    results = project.run_gates("my-slice", lane: "lane-a")
    elapsed = Time.now - t0

    assert_equal 1, results.length
    assert_equal :fail, results[0][:status]
    assert_match(/timed out/, results[0][:reason])
    assert_nil results[0][:exit_code]
    # capture_with_timeout waits a fixed 0.5s between TERM and KILL, so the
    # floor here is ~0.2s (gate timeout) + 0.5s, not the gate timeout alone.
    assert elapsed < 3, "timeout-kill test took #{elapsed.round(1)}s — expected ~0.7s"
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

  # ── I10: init! idempotency + settings.json scaffolding ──────────────────────

  # init! writes .claude/settings.json on first call alongside ARCHITECT.md.
  def test_init_writes_settings_json_on_first_call
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    settings_path = File.join(dir, ".claude", "settings.json")
    assert_path_exists settings_path
    parsed = JSON.parse(File.read(settings_path))
    matchers = parsed.dig("hooks", "SessionStart").map { |e| e["matcher"] }
    assert_includes matchers, "startup"
    assert_includes matchers, "clear"
    assert_includes matchers, "resume"
    parsed.dig("hooks", "SessionStart").each do |entry|
      hook = entry["hooks"].first
      assert_equal "command", hook["type"]
      assert_equal "architect", hook["command"]
      assert_equal ["ground"], hook["args"]
    end
  ensure
    FileUtils.rm_rf(dir)
  end

  # init! is idempotent: second call does not raise, does not overwrite ARCHITECT.md,
  # and leaves a pre-existing settings.json untouched.
  def test_init_idempotent_no_raise_settings_json_unmodified_on_second_call
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    architect_before = File.read(File.join(dir, "architecture", "ARCHITECT.md"))
    settings_before  = File.read(File.join(dir, ".claude", "settings.json"))

    space2 = Space::Core::Space.load(dir)
    project2 = Space::Architect::ArchitectProject.new(space: space2)
    result = project2.init!

    assert_equal File.join(dir, "architecture", "ARCHITECT.md"), result.to_s
    assert_equal architect_before, File.read(File.join(dir, "architecture", "ARCHITECT.md")),
      "ARCHITECT.md must not be overwritten on second call"
    assert_equal settings_before, File.read(File.join(dir, ".claude", "settings.json")),
      "settings.json must not be overwritten on second call"
  ensure
    FileUtils.rm_rf(dir)
  end

  # init! writes settings.json even when ARCHITECT.md already exists (upgrade path
  # for spaces initialized before the settings.json feature was added).
  def test_init_writes_settings_json_when_architect_md_exists_but_settings_absent
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    original_architect = File.read(File.join(dir, "architecture", "ARCHITECT.md"))

    # Simulate older space: remove settings.json and commit the removal
    settings_path = File.join(dir, ".claude", "settings.json")
    File.delete(settings_path)
    system("git", "-C", dir, "rm", "-q", ".claude/settings.json")
    system("git", "-C", dir, "commit", "-q", "-m", "remove settings for upgrade-path test")

    space2 = Space::Core::Space.load(dir)
    project2 = Space::Architect::ArchitectProject.new(space: space2)
    project2.init!

    assert_path_exists settings_path, "settings.json must be written when absent"
    assert_equal original_architect, File.read(File.join(dir, "architecture", "ARCHITECT.md")),
      "ARCHITECT.md must not be overwritten during settings-only init"
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── I10: architect ground ────────────────────────────────────────────────────

  # ground emits ARCHITECT.md, BRIEF.md, and the in-flight iteration under delimiters.
  # CLAUDE.md is never re-emitted (Claude Code auto-loads it).
  def test_ground_emits_architect_brief_and_inflight_iteration
    dir = Dir.mktmpdir("architect-ground-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.brief_new!
    project.new_iteration!("my-slice")

    result = project.ground(session_cwd: dir)

    assert_match(/=== architecture\/ARCHITECT\.md ===/, result)
    assert_match(/=== architecture\/BRIEF\.md ===/, result)
    assert_match(/=== architecture\/I01-my-slice\.md ===/, result)
    refute_match(/=== .*CLAUDE\.md ===/, result, "CLAUDE.md delimiter must not appear")
    # Delimiter order: ARCHITECT.md before BRIEF.md before iteration
    architect_idx = result.index("ARCHITECT.md")
    brief_idx     = result.index("BRIEF.md")
    iter_idx      = result.index("I01-my-slice.md")
    assert architect_idx < brief_idx,  "ARCHITECT.md must precede BRIEF.md"
    assert brief_idx < iter_idx,       "BRIEF.md must precede the iteration file"
  ensure
    FileUtils.rm_rf(dir)
  end

  # ground: BRIEF.md omitted when absent (discovery spaces may lack it).
  def test_ground_omits_brief_when_absent
    dir = Dir.mktmpdir("architect-ground-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    result = project.ground(session_cwd: dir)

    assert_match(/=== architecture\/ARCHITECT\.md ===/, result)
    refute_match(/=== architecture\/BRIEF\.md ===/, result, "BRIEF.md delimiter must not appear when file does not exist")
    assert_match(/=== architecture\/I01-my-slice\.md ===/, result)
  ensure
    FileUtils.rm_rf(dir)
  end

  # ground: highest-ordinal fallback when current_iteration is cleared.
  # Deterministic rule pinned by this test.
  def test_ground_resolves_inflight_by_highest_ordinal_when_current_iteration_absent
    dir = Dir.mktmpdir("architect-ground-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("first-slice")
    project.new_iteration!("second-slice")

    # Clear current_iteration in memory to exercise the highest-ordinal fallback
    space.data["project"]["current_iteration"] = nil

    result = project.ground(session_cwd: dir)

    assert_match(/I02-second-slice/, result, "highest-ordinal iteration must be selected")
    refute_match(/I01-first-slice/, result, "lower-ordinal iteration must not appear")
  ensure
    FileUtils.rm_rf(dir)
  end

  # WORKTREE GUARD: session cwd is the builder wt dir itself → empty output, exit 0.
  def test_ground_returns_empty_when_session_cwd_is_builder_worktree
    dir = Dir.mktmpdir("architect-ground-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    wt_cwd = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    result = project.ground(session_cwd: wt_cwd)

    assert_equal "", result, "ground must emit nothing when session cwd is inside a builder worktree"
  ensure
    FileUtils.rm_rf(dir)
  end

  # WORKTREE GUARD: session cwd is a subdirectory inside the wt → still guarded.
  def test_ground_returns_empty_when_session_cwd_is_inside_builder_worktree
    dir = Dir.mktmpdir("architect-ground-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    wt_sub = File.join(dir, "build", "I01-my-slice-lane-a", "wt", "lib", "sub")
    result = project.ground(session_cwd: wt_sub)

    assert_equal "", result, "ground must emit nothing when session cwd is deep inside a builder worktree"
  ensure
    FileUtils.rm_rf(dir)
  end

  # WORKTREE GUARD: session cwd is the space root → not guarded, emits content.
  def test_ground_not_guarded_when_session_cwd_is_space_root
    dir = Dir.mktmpdir("architect-ground-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    result = project.ground(session_cwd: dir)

    assert_match(/=== architecture\/ARCHITECT\.md ===/, result)
  ensure
    FileUtils.rm_rf(dir)
  end

  # WORKTREE GUARD: cwd under build/ but NOT at the wt level → not guarded.
  def test_ground_not_guarded_when_session_cwd_is_build_dir_not_wt
    dir = Dir.mktmpdir("architect-ground-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    build_sub = File.join(dir, "build", "I01-my-slice-lane-a")  # no /wt
    result = project.ground(session_cwd: build_sub)

    assert_match(/=== architecture\/ARCHITECT\.md ===/, result)
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── I13: worktree_add idempotency + prompt seeding (AC3, AC4) ─────────────

  # AC3: second worktree_add call for the same lane yields exactly one entry.
  def test_worktree_add_is_idempotent_for_same_lane
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    project.worktree_add("my-repo", "my-slice", "lane-a")
    project.worktree_add("my-repo", "my-slice", "lane-a")  # second call — must not append

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lanes = yml.dig("project", "iterations", 0, "lanes") || []
    assert_equal 1, lanes.length, "exactly one lane entry after two identical worktree_add calls"
    assert_equal "lane-a", lanes.first["name"]
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC3: re-run updates recorded fields (e.g. model) in place.
  def test_worktree_add_re_add_updates_entry_in_place
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    project.worktree_add("my-repo", "my-slice", "lane-a", model: "first-model")
    project.worktree_add("my-repo", "my-slice", "lane-a", model: "second-model")

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lanes = yml.dig("project", "iterations", 0, "lanes") || []
    assert_equal 1,              lanes.length
    assert_equal "second-model", lanes.first["model"]
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC3: directory exists but is NOT a registered worktree → clear error.
  def test_worktree_add_raises_when_directory_not_a_registered_worktree
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    # Pre-create the worktree path as a plain directory (not via git).
    stray_dir = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    FileUtils.mkdir_p(stray_dir)

    err = assert_raises(Space::Core::Error) do
      project.worktree_add("my-repo", "my-slice", "lane-a")
    end
    assert_match(/exists but is not a registered git worktree/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # worktree_add never creates prompt.md — the pre-seeded stub tripped harness
  # read-before-write guards on the caller's first Write (#48). The prompt is
  # authored by the architect (or copied in by dispatch --prompt).
  def test_worktree_add_does_not_seed_prompt
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    prompt_path = File.join(dir, "build", "I01-my-slice-lane-a", "prompt.md")
    refute File.exist?(prompt_path), "worktree_add must not seed prompt.md"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4: re-running worktree_add does NOT clobber an existing real prompt.
  def test_worktree_add_does_not_clobber_real_prompt_on_re_add
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    prompt_path = File.join(dir, "build", "I01-my-slice-lane-a", "prompt.md")
    File.write(prompt_path, "## Real prompt written by architect\n")

    project.worktree_add("my-repo", "my-slice", "lane-a")  # re-run

    assert_equal "## Real prompt written by architect\n", File.read(prompt_path),
      "real prompt must not be overwritten on re-add"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4: dispatch refuses when prompt.md is missing.
  def test_dispatch_refuses_missing_prompt
    dir = Dir.mktmpdir("architect-dispatch-guard")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")

    err = assert_raises(Space::Core::Error) { project.dispatch("demo", "A") }
    assert_match(/prompt\.md not found/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4: dispatch refuses when prompt.md is empty.
  def test_dispatch_refuses_empty_prompt
    dir = Dir.mktmpdir("architect-dispatch-guard")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")
    File.write(File.join(dir, "build", "I01-demo-A", "prompt.md"), "   \n")

    err = assert_raises(Space::Core::Error) { project.dispatch("demo", "A") }
    assert_match(/Write this lane's prompt/, err.message)
    assert_includes err.message, "prompt.md"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4: dispatch refuses when prompt.md contains the unedited stub (legacy
  # spaces provisioned before the seeding was dropped may still carry one).
  def test_dispatch_refuses_stub_prompt
    dir = Dir.mktmpdir("architect-dispatch-guard")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")
    File.write(File.join(dir, "build", "I01-demo-A", "prompt.md"),
      "#{Space::Architect::ArchitectProject::PROMPT_STUB}\n")

    err = assert_raises(Space::Core::Error) { project.dispatch("demo", "A") }
    assert_match(/Write this lane's prompt/, err.message)
    assert_includes err.message, "prompt.md"
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── I14: Fix B — frozen cwd re-rooting onto the lane worktree ────────────

  # A gate with cwd: repos/<repo> runs in the lane worktree, not the repo
  # checkout — proved by a marker file written only in the worktree.
  def test_run_gates_reroots_cwd_into_lane_worktree
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    slice = File.join(dir, "architecture", "I01-my-slice.md")
    text = File.read(slice)
    gate_yaml = <<~YAML
      - id: worktree-marker-gate
        ac: AC1
        cmd: cat worktree-marker.txt
        cwd: repos/my-repo
        expect:
          exit_code: 0
          stdout_match: "worktree-only"
    YAML
    text = text.sub(/^```gates\n.*?^```/m, "```gates\n#{gate_yaml}```")
    File.write(slice, text)
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    # Write marker ONLY in the worktree — not present in repos/my-repo
    wt = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    File.write(File.join(wt, "worktree-marker.txt"), "worktree-only\n")

    results = project.run_gates("my-slice", lane: "lane-a")
    assert_equal 1, results.length
    assert_equal :pass, results[0][:status], results[0][:reason]
  ensure
    FileUtils.rm_rf(dir)
  end

  # A gate with cwd: repos/<repo>/subdir re-roots to <worktree>/subdir.
  def test_run_gates_reroots_cwd_subdir_into_lane_worktree
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    slice = File.join(dir, "architecture", "I01-my-slice.md")
    text = File.read(slice)
    gate_yaml = <<~YAML
      - id: subdir-gate
        ac: AC1
        cmd: cat sub-marker.txt
        cwd: repos/my-repo/subdir
        expect:
          exit_code: 0
          stdout_match: "sub-only"
    YAML
    text = text.sub(/^```gates\n.*?^```/m, "```gates\n#{gate_yaml}```")
    File.write(slice, text)
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    # Create subdir ONLY in the worktree and write marker there
    wt = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    FileUtils.mkdir_p(File.join(wt, "subdir"))
    File.write(File.join(wt, "subdir", "sub-marker.txt"), "sub-only\n")

    results = project.run_gates("my-slice", lane: "lane-a")
    assert_equal 1, results.length
    assert_equal :pass, results[0][:status], results[0][:reason]
  ensure
    FileUtils.rm_rf(dir)
  end

  # A gate with cwd outside the lane's repo is honored literally.
  def test_run_gates_honors_cwd_outside_repo
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    slice = File.join(dir, "architecture", "I01-my-slice.md")
    text = File.read(slice)
    gate_yaml = <<~YAML
      - id: outside-cwd-gate
        ac: AC1
        cmd: cat outside-canary.txt
        cwd: architecture
        expect:
          exit_code: 0
          stdout_match: "outside-canary"
    YAML
    text = text.sub(/^```gates\n.*?^```/m, "```gates\n#{gate_yaml}```")
    File.write(slice, text)
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    # Write canary in architecture/ (outside repos/my-repo)
    File.write(File.join(dir, "architecture", "outside-canary.txt"), "outside-canary\n")

    results = project.run_gates("my-slice", lane: "lane-a")
    assert_equal 1, results.length
    assert_equal :pass, results[0][:status], results[0][:reason]
  ensure
    FileUtils.rm_rf(dir)
  end

  # A gate with no cwd still uses the worktree base_dir when a lane is given.
  def test_run_gates_no_cwd_uses_worktree_when_lane_given
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    slice = File.join(dir, "architecture", "I01-my-slice.md")
    text = File.read(slice)
    gate_yaml = <<~YAML
      - id: base-dir-gate
        ac: AC1
        cmd: cat wt-base.txt
        expect:
          exit_code: 0
          stdout_match: "wt-base"
    YAML
    text = text.sub(/^```gates\n.*?^```/m, "```gates\n#{gate_yaml}```")
    File.write(slice, text)
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    wt = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    File.write(File.join(wt, "wt-base.txt"), "wt-base\n")

    results = project.run_gates("my-slice", lane: "lane-a")
    assert_equal 1, results.length
    assert_equal :pass, results[0][:status], results[0][:reason]
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC1: integrate! with no lanes and no teardown raises a friendly usage error,
  # not "missing keyword" — the CLI is the ArgumentError-avoidance layer, this
  # is the underlying guard it relies on.
  def test_integrate_bang_raises_without_lanes_or_teardown
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")

    err = assert_raises(Space::Core::Error) { project.integrate!("my-slice") }
    assert_match(/No lanes given to integrate/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2: integrate! with teardown: true and no lanes tears down every RECORDED
  # lane for the iteration (not just ones merged in this call) — removes the
  # worktree and safe-deletes the lane branch.
  def test_integrate_bang_teardown_only_over_recorded_lanes
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
    project.merge_lane!("my-slice", "lane-a")

    results = project.integrate!("my-slice", teardown: true)
    assert_equal [{ lane: "lane-a", repo: "my-repo", lane_branch: "lane/I01-my-slice-lane-a" }], results

    refute_path_exists wt, "expected lane worktree to be removed"
    branch_ref = File.join(dir, "repos", "my-repo", ".git", "refs", "heads", "lane", "I01-my-slice-lane-a")
    refute_path_exists branch_ref, "expected lane branch to be deleted"

    repo = File.join(dir, "repos", "my-repo")
    branches, = Open3.capture3("git", "-C", repo, "branch", "--list")
    assert_match(/project\/test/, branches, "the persistent project branch must survive teardown")
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2: teardown-only on an iteration with no recorded lanes is a no-op that
  # returns an empty result set (the CLI prints "Nothing to tear down").
  def test_integrate_bang_teardown_only_with_no_lanes_recorded
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")

    assert_equal [], project.integrate!("my-slice", teardown: true)
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── I03: lane-declaration model ──────────────────────────────────────────────

  # Write a full iteration file with a ```lanes block (and optional ```gates block),
  # replacing the scaffold, so freeze parses declarations from the Specification.
  def write_iteration_with_lanes(dir, name, lanes_yaml, gates_yaml: nil)
    gates = gates_yaml ? "\n```gates\n#{gates_yaml}```\n" : ""
    File.write(File.join(dir, "architecture", "I01-#{name}.md"), <<~MD)
      # I01: #{name}

      ## Grounds

      ## Specification

      Build stuff.

      ```lanes
      #{lanes_yaml}```

      ## Acceptance Criteria
      #{gates}
      ## Builder Prompt

      ## Builder Report

      ## Verdict
    MD
  end

  # AC1: freeze parses the ```lanes block and writes name/repo/touch_set into the
  # iteration's space.yaml lane entries in the freeze operation.
  def test_freeze_populates_lane_entries_from_lanes_block
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    write_iteration_with_lanes(dir, "my-slice", <<~YAML)
      - name: lane-a
        repo: my-repo
        touch:
          - lib/**
      - name: lane-b
        repo: my-repo
        touch:
          - test/**
    YAML

    project.freeze!("my-slice")

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    lanes = yml.dig("project", "iterations", 0, "lanes")
    assert_equal %w[lane-a lane-b], lanes.map { |l| l["name"] }
    assert_equal "my-repo", lanes[0]["repo"]
    assert_equal ["lib/**"], lanes[0]["touch_set"]
    assert_equal ["test/**"], lanes[1]["touch_set"]
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC1: a lane already recorded (e.g. by worktree_add) is updated in place — not
  # duplicated — and re-freeze is a no-op.
  def test_freeze_updates_recorded_lane_in_place_and_refreeze_is_noop
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a", harness: "opencode", model: "some/model")
    write_iteration_with_lanes(dir, "my-slice", <<~YAML)
      - name: lane-a
        repo: my-repo
        touch:
          - lib/**
    YAML

    sha = project.freeze!("my-slice")

    lanes = space.data.dig("project", "iterations", 0, "lanes")
    assert_equal 1, lanes.length, "declared lane must merge into the recorded entry, not duplicate"
    assert_equal ["lib/**"], lanes[0]["touch_set"]
    assert_equal "opencode", lanes[0]["harness"], "worktree_add fields survive freeze-populate"

    assert_equal sha, project.freeze!("my-slice"), "re-freeze returns the same sha"
    assert_equal 1, space.data.dig("project", "iterations", 0, "lanes").length
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC1: a malformed ```lanes block (missing repo) fails freeze with a clear error.
  def test_freeze_rejects_malformed_lanes_block
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    write_iteration_with_lanes(dir, "my-slice", <<~YAML)
      - name: lane-a
        touch:
          - lib/**
    YAML

    err = assert_raises(Space::Core::Error) { project.freeze!("my-slice") }
    assert_match(/ill-formed lanes block/, err.message)
    assert_match(/missing 'repo'/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # freeze! commits space.yaml after update_architect_block so the workspace is clean:
  # (a) git status --porcelain is empty; (b) freeze_sha in space.yaml equals the freeze
  # commit (iteration file), not HEAD (the metadata commit).
  def test_freeze_commits_space_yaml
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    # Dirty the iteration file so the freeze produces a distinct first commit
    slice = File.join(dir, "architecture", "I01-my-slice.md")
    File.write(slice, File.read(slice) + "\nAC1 — the seam holds.\n")

    freeze_sha = project.freeze!("my-slice")

    # (a) space.yaml committed — no dirty working tree
    status, = Open3.capture3("git", "-C", dir, "status", "--porcelain")
    assert_equal "", status.strip

    # (b) freeze_sha in space.yaml equals the freeze commit (touching the iteration file),
    # not HEAD (the metadata commit)
    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    recorded = yml.dig("project", "iterations", 0, "freeze_sha")
    assert_equal freeze_sha, recorded

    iter_commit, = Open3.capture3("git", "-C", dir, "log", "--format=%H", "--", "architecture/I01-my-slice.md")
    head, = Open3.capture3("git", "-C", dir, "rev-parse", "HEAD")
    assert_equal iter_commit.lines.first.strip, recorded
    refute_equal head.strip, recorded
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2: provision materializes every declared lane (worktree + lane branch), is
  # idempotent, records base_sha, and refuses when the iteration is not frozen.
  def test_provision_materializes_declared_lanes_and_is_idempotent
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    write_iteration_with_lanes(dir, "my-slice", <<~YAML)
      - name: lane-a
        repo: my-repo
        touch:
          - lib/**
    YAML

    err = assert_raises(Space::Core::Error) { project.provision("my-slice") }
    assert_match(/not frozen/, err.message)

    project.freeze!("my-slice")

    created = project.provision("my-slice")
    assert_equal ["lane-a"], created.map { |r| r[:lane] }
    assert created[0][:created], "first provision creates the worktree"
    assert_path_exists created[0][:worktree].to_s
    branch_ref = File.join(dir, "repos", "my-repo", ".git", "refs", "heads", "lane", "I01-my-slice-lane-a")
    assert_path_exists branch_ref

    lane = space.data.dig("project", "iterations", 0, "lanes", 0)
    assert_equal "build/I01-my-slice-lane-a/wt", lane["worktree"]
    assert_match(/\A[0-9a-f]{40}\z/, lane["base_sha"])

    again = project.provision("my-slice")
    refute again[0][:created], "second provision skips the already-materialized lane"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC3: with a declared lane whose worktree is absent, a resolution call site
  # (run_gates) auto-materializes it from the declaration rather than dead-ending.
  def test_run_gates_auto_materializes_missing_worktree
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    write_iteration_with_lanes(dir, "my-slice", <<~YAML, gates_yaml: <<~GATES)
      - name: lane-a
        repo: my-repo
        touch:
          - lib/**
    YAML
      - id: g1
        ac: AC1
        cmd: "true"
        expect:
          exit_code: 0
    GATES

    project.freeze!("my-slice")
    refute_path_exists File.join(dir, "build", "I01-my-slice-lane-a", "wt")

    results = project.run_gates("my-slice", lane: "lane-a")
    assert_equal :pass, results[0][:status]
    assert_path_exists File.join(dir, "build", "I01-my-slice-lane-a", "wt"),
      "gate run must materialize the declared lane's worktree"
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── I05: dispatched_at, field-clobber, surviving-branch re-materialize ────────

  ISO8601_RE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:\d{2})\z/

  # A fake claude bin that consumes stdin and exits 0 quickly (so the default liveness
  # fiber is stopped on child exit — no test slowdown).
  FAKE_CLAUDE_OK = <<~RUBY
    #!/usr/bin/env ruby
    $stdin.read
    exit 0
  RUBY

  def write_fake_claude(dir)
    bin = File.join(dir, "fake_claude")
    File.write(bin, FAKE_CLAUDE_OK)
    File.chmod(0o755, bin)
    bin
  end

  def lane_on_disk(dir, name)
    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    demo = yml.dig("project", "iterations").find { |i| i["name"] == "demo" }
    (demo["lanes"] || []).find { |l| l["name"] == name }
  end

  # AC1: a foreground dispatch records an ISO 8601 dispatched_at on the lane entry.
  def test_dispatch_records_dispatched_at_on_foreground
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")
    File.write(File.join(dir, "build", "I01-demo-A", "prompt.md"), "real prompt here\n")

    project.dispatch("demo", "A", claude_bin: write_fake_claude(dir))

    stamp = lane_on_disk(dir, "A")["dispatched_at"]
    assert_match ISO8601_RE, stamp, "dispatched_at must be ISO 8601, got #{stamp.inspect}"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC1: a detached dispatch also records dispatched_at before it returns.
  def test_dispatch_records_dispatched_at_on_detached
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")
    File.write(File.join(dir, "build", "I01-demo-A", "prompt.md"), "real prompt here\n")

    res = project.dispatch("demo", "A", claude_bin: write_fake_claude(dir), detach: true)
    assert res[:pid], "detached dispatch returns a pid"

    stamp = lane_on_disk(dir, "A")["dispatched_at"]
    assert_match ISO8601_RE, stamp, "detached dispatch must record dispatched_at, got #{stamp.inspect}"
  ensure
    Process.kill("KILL", res[:pid]) rescue nil if defined?(res) && res.is_a?(Hash)
    FileUtils.rm_rf(dir)
  end

  # AC1: a re-dispatch overwrites a prior dispatched_at value.
  def test_dispatch_overwrites_prior_dispatched_at
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")
    File.write(File.join(dir, "build", "I01-demo-A", "prompt.md"), "real prompt here\n")

    # Seed a sentinel value directly on the lane entry the project holds in memory.
    space.data.dig("project", "iterations", 0, "lanes", 0)["dispatched_at"] = "SENTINEL"
    space.save

    project.dispatch("demo", "A", claude_bin: write_fake_claude(dir))

    stamp = lane_on_disk(dir, "A")["dispatched_at"]
    refute_equal "SENTINEL", stamp, "re-dispatch must overwrite the prior value"
    assert_match ISO8601_RE, stamp
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC1: a dispatch that raises during preflight records nothing.
  def test_dispatch_records_nothing_when_preflight_raises
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")
    # prompt.md left as the seeded stub → dispatch raises before launch.

    assert_raises(Space::Core::Error) do
      project.dispatch("demo", "A", claude_bin: write_fake_claude(dir))
    end

    refute lane_on_disk(dir, "A").key?("dispatched_at"),
      "a dispatch that raises in preflight must record no dispatched_at"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4: re-materialize via ensure_lane_materialized preserves harness/model/variant/
  # effort/touch_set (threaded through worktree_add, not merged back to defaults).
  def test_ensure_lane_materialized_preserves_recorded_fields
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "V",
                         harness: "opencode",
                         model: "fireworks-ai/custom-model",
                         variant: true,
                         effort: "high",
                         touch: ["lib/**"])

    project.worktree_remove("demo", "V")
    assert_nil lane_on_disk(dir, "V")["worktree"], "worktree nilled after removal"

    project.send(:ensure_lane_materialized, "demo", "V")

    lane = lane_on_disk(dir, "V")
    assert_equal "opencode",                 lane["harness"]
    assert_equal "fireworks-ai/custom-model", lane["model"]
    assert_equal true,                       lane["variant"]
    assert_equal "high",                     lane["effort"]
    assert_equal ["lib/**"],                 lane["touch_set"]
    assert_equal "build/I01-demo-V/wt",      lane["worktree"], "worktree re-materialized"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4: re-materialize via provision preserves the same recorded fields.
  def test_provision_preserves_recorded_fields_on_rematerialize
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    write_iteration_with_lanes(dir, "demo", <<~YAML)
      - name: V
        repo: my-repo
        touch:
          - lib/**
    YAML
    project.freeze!("demo")
    # Record harness/model/variant/effort onto the frozen lane via worktree_add.
    project.worktree_add("my-repo", "demo", "V",
                         harness: "opencode",
                         model: "fireworks-ai/custom-model",
                         variant: true,
                         effort: "high")

    project.worktree_remove("demo", "V")
    project.provision("demo")

    lane = lane_on_disk(dir, "V")
    assert_equal "opencode",                  lane["harness"]
    assert_equal "fireworks-ai/custom-model", lane["model"]
    assert_equal true,                        lane["variant"]
    assert_equal "high",                      lane["effort"]
    assert_equal ["lib/**"],                  lane["touch_set"], "touch_set stays preserved"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC5: re-materialize over a surviving lane branch checks it out (no -b), carrying
  # the branch's own tip rather than failing "branch already exists".
  def test_rematerialize_reattaches_surviving_branch_with_its_tip
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    repo_dir = create_real_repo(dir, "my-repo")
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")

    # Advance the lane branch's tip with a commit made in the worktree.
    wt = File.join(dir, "build", "I01-demo-A", "wt")
    File.write(File.join(wt, "new.txt"), "hi\n")
    system("git", "-C", wt, "add", "new.txt", out: File::NULL, err: File::NULL)
    system("git", "-C", wt, "commit", "-q", "-m", "advance tip")
    branch_tip, _, st = Open3.capture3("git", "-C", repo_dir, "rev-parse", "lane/I01-demo-A")
    assert st.success?
    branch_tip = branch_tip.strip

    # Remove the worktree; the lane/I01-demo-A branch survives at branch_tip.
    project.worktree_remove("demo", "A")
    assert project.send(:branch_exists?, Pathname.new(repo_dir), "lane/I01-demo-A"),
      "lane branch must survive worktree removal"

    # Re-materialize: must succeed (not raise "branch already exists").
    project.send(:ensure_lane_materialized, "demo", "A")

    head, _, st2 = Open3.capture3("git", "-C", wt, "rev-parse", "HEAD")
    assert st2.success?, "re-attached worktree must exist"
    assert_equal branch_tip, head.strip, "re-attached worktree carries the branch's own tip"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4: an iteration frozen with no ```lanes block still works — freeze adds no
  # lanes, and provision reads the pre-existing worktree_add entry unchanged.
  def test_no_lanes_block_falls_back_to_recorded_entries
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice") # scaffold carries only a commented (inert) lanes stub

    assert_equal [], space.data.dig("project", "iterations", 0, "lanes"),
      "an absent/commented lanes block populates nothing"

    project.worktree_add("my-repo", "my-slice", "lane-a")
    results = project.provision("my-slice")
    assert_equal ["lane-a"], results.map { |r| r[:lane] }
    refute results[0][:created], "provision reads the pre-existing worktree_add entry, already materialized"
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── dispatch --prompt: the CLI owns the canonical prompt.md copy ───────────

  def test_dispatch_prompt_copies_file_to_build_dir
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")

    scratch = File.join(dir, "tmp-lane-prompt.md")
    File.write(scratch, "## Lane prompt\n\nBuild the thing. — bytes: é✓\n")

    res = project.dispatch("demo", "A", claude_bin: write_fake_claude(dir), prompt: scratch)

    copied = File.join(dir, "build", "I01-demo-A", "prompt.md")
    assert_equal File.binread(scratch), File.binread(copied), "prompt.md must be a byte-for-byte copy"
    assert_equal copied, res[:prompt_copied].to_s
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_dispatch_prompt_missing_file_raises
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")

    err = assert_raises(Space::Core::Error) do
      project.dispatch("demo", "A", prompt: File.join(dir, "nope.md"))
    end
    assert_match(/prompt file not found/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── brief_new! with authored content ───────────────────────────────────────

  def test_brief_new_with_content_writes_authored_brief
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    body = "# Brief\n\n## §1 Goal\n\nShip it.\n"
    path = project.brief_new!(content: body)

    assert_equal body, File.read(path)
    msg, = Open3.capture3("git", "-C", dir, "log", "-1", "--format=%s")
    assert_equal "Add project brief", msg.strip
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── commit message composition: canonical prefix + author subject/body ─────

  def last_commit(dir, format)
    out, = Open3.capture3("git", "-C", dir, "log", "-1", "--format=#{format}")
    out.strip
  end

  def test_init_message_composes_prefixed_subject_and_body
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    project = Space::Architect::ArchitectProject.new(space: space)

    project.init!(message: "stand up the argo loop\n\nWhy: migrate the homelab to gitops.")

    assert_equal "init: stand up the argo loop", last_commit(dir, "%s")
    assert_equal "Why: migrate the homelab to gitops.", last_commit(dir, "%b")
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_new_iteration_message_composes_single_line
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    project.new_iteration!("my-slice", message: "first slice off the brief")

    assert_equal "I01 scaffold: first slice off the brief", last_commit(dir, "%s")
    assert_equal "", last_commit(dir, "%b")
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_freeze_message_composes_subject_and_body
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    # Dirty the iteration file so the freeze produces a real commit (an
    # untouched scaffold freezes onto the scaffold commit).
    slice = File.join(dir, "architecture", "I01-my-slice.md")
    File.write(slice, File.read(slice) + "\nAC1 — the seam holds.\n")

    project.freeze!("my-slice", message: "AC pinned to BRIEF §3\n\nGate g1 covers the seam;\ng2 covers idempotence.")

    assert_equal "I01 freeze: AC pinned to BRIEF §3", last_commit(dir, "%s")
    assert_match(/g2 covers idempotence\./, last_commit(dir, "%b"))
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_write_section_message_composes_spec_prefix
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    project.write_section!("my-slice", "specification", body: "- Objective — the seam",
      message: "pull-based dispatcher seam\n\nRejected push: reactor starvation risk.")

    assert_equal "I01 spec: pull-based dispatcher seam", last_commit(dir, "%s")
    assert_equal "Rejected push: reactor starvation risk.", last_commit(dir, "%b")
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_record_verdict_message_composes
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    project.record_verdict!("my-slice", decision: "continue", body: "AC1 PASS",
      message: "all ACs pass on raw gate output")

    assert_equal "I01 verdict: all ACs pass on raw gate output", last_commit(dir, "%s")
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_transcribe_evidence_message_composes
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    FileUtils.mkdir_p(File.join(dir, "build", "I01-my-slice"))
    File.write(File.join(dir, "build", "I01-my-slice", "report.md"), "STATUS: green\n")

    project.transcribe_evidence!("my-slice", message: "builder reports green, 12 new tests")

    assert_equal "I01 evidence: builder reports green, 12 new tests", last_commit(dir, "%s")
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_brief_new_message_composes
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    project.brief_new!(content: "# Brief\n", message: "founding contract for the migration")

    assert_equal "brief: founding contract for the migration", last_commit(dir, "%s")
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_merge_lane_message_composes_on_lane_branch
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

    project.merge_lane!("my-slice", "lane-a",
      message: "add the feature seam\n\nCovers AC1; touch set repos/my-repo/feature.rb only.")

    repo = File.join(dir, "repos", "my-repo")
    log, = Open3.capture3("git", "-C", repo, "log", "lane/I01-my-slice-lane-a", "-2", "--format=%s")
    assert_includes log, "lane lane-a: add the feature seam"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC1: --into <branch> merges into the named branch (creates if absent, checks out if present)
  # and records it in space.yaml's integration_branch field.
  def test_merge_lane_into_branch
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")
    repo = File.join(dir, "repos", "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    # (a) branch absent — must be created off base_sha
    project.new_iteration!("s1")
    project.freeze!("s1")
    project.worktree_add("my-repo", "s1", "lane-a")
    File.write(File.join(dir, "build", "I01-s1-lane-a", "wt", "feature.rb"), "def f; end\n")

    r = project.merge_lane!("s1", "lane-a", into: "my-target")
    assert_equal "my-target", r[:integration_branch]
    assert_equal false, r[:gates_run]

    branch_parts = "my-target".split("/")
    assert_path_exists File.join(repo, ".git", "refs", "heads", *branch_parts),
      "into branch must be created in the repo"

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    assert_equal "my-target", yml.dig("project", "iterations", 0, "lanes", 0, "integration_branch"),
      "lane integration_branch must be recorded in space.yaml"

    # (b) branch already exists — must be checked out and merged into
    project.new_iteration!("s2")
    project.freeze!("s2")
    project.worktree_add("my-repo", "s2", "lane-b")
    File.write(File.join(dir, "build", "I02-s2-lane-b", "wt", "feature2.rb"), "def f2; end\n")

    r2 = project.merge_lane!("s2", "lane-b", into: "my-target")
    assert_equal "my-target", r2[:integration_branch]

    log, = Open3.capture3("git", "-C", repo, "log", "my-target", "--format=%s")
    assert_match(/Merge lane\/I01-s1-lane-a/, log)
    assert_match(/Merge lane\/I02-s2-lane-b/, log)
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2: conflict outside touch_set → branch-mismatch error mentioning --into / target branch.
  # AC2: conflict inside touch_set → "spec defect" error preserved.
  def test_merge_lane_conflict_message_outside_touch_set
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")
    repo = File.join(dir, "repos", "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    # (outside touch_set) — lane has no touch_set; conflict on other.rb → branch-mismatch
    project.new_iteration!("s1")
    project.freeze!("s1")
    project.worktree_add("my-repo", "s1", "lane-a")

    base_sha, = Open3.capture3("git", "-C", repo, "rev-parse", "HEAD")
    base_sha = base_sha.strip

    # pre-create integration branch with other.rb at version "ib"
    system("git", "-C", repo, "checkout", "-b", "conflict-ib", base_sha, out: File::NULL, err: File::NULL)
    File.write(File.join(repo, "other.rb"), "def other; :ib; end\n")
    system("git", "-C", repo, "add", "other.rb", out: File::NULL, err: File::NULL)
    system("git", "-C", repo, "commit", "-q", "-m", "ib baseline")
    system("git", "-C", repo, "checkout", "-", out: File::NULL, err: File::NULL)

    # lane writes other.rb at version "lane"
    File.write(File.join(dir, "build", "I01-s1-lane-a", "wt", "other.rb"), "def other; :lane; end\n")

    err = assert_raises(Space::Core::Error) { project.merge_lane!("s1", "lane-a", into: "conflict-ib") }
    assert_match(/--into/, err.message, "outside-touch-set conflict must mention --into")
    assert_match(/conflict-ib/, err.message, "outside-touch-set conflict must name the target branch")
    refute_match(/spec defect/, err.message, "outside-touch-set conflict must NOT say 'spec defect'")

    # (inside touch_set) — lane touch_set covers the conflicting file → spec defect
    project.new_iteration!("s2")
    project.freeze!("s2")
    project.worktree_add("my-repo", "s2", "lane-b", touch: ["feature.rb"])

    base_sha2, = Open3.capture3("git", "-C", repo, "rev-parse", "HEAD")
    base_sha2 = base_sha2.strip

    system("git", "-C", repo, "checkout", "-b", "conflict-ib2", base_sha2, out: File::NULL, err: File::NULL)
    File.write(File.join(repo, "feature.rb"), "def feature; :ib; end\n")
    system("git", "-C", repo, "add", "feature.rb", out: File::NULL, err: File::NULL)
    system("git", "-C", repo, "commit", "-q", "-m", "ib2 baseline")
    system("git", "-C", repo, "checkout", "-", out: File::NULL, err: File::NULL)

    File.write(File.join(dir, "build", "I02-s2-lane-b", "wt", "feature.rb"), "def feature; :lane; end\n")

    err2 = assert_raises(Space::Core::Error) { project.merge_lane!("s2", "lane-b", into: "conflict-ib2") }
    assert_match(/spec defect/, err2.message, "inside-touch-set conflict must say 'spec defect'")
    refute_match(/--into/, err2.message, "inside-touch-set conflict must NOT mention --into")
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── I05: repo sync command + ground staleness warning ───────────────────────

  # AC1: sync_repos fast-forwards a behind repo, reports up-to-date for current,
  #      and refuses dirty/diverged repos without clobbering the ref.
  def test_sync_fast_forwards_behind_repo
    dir        = Dir.mktmpdir("architect-sync-test")
    origin_dir = Dir.mktmpdir("architect-sync-origin-test")

    # Set up local "origin"
    system("git", "-C", origin_dir, "init", "-q", "-b", "main", exception: false) ||
      system("git", "-C", origin_dir, "init", "-q")
    system("git", "-C", origin_dir, "config", "user.name", "Test Builder")
    system("git", "-C", origin_dir, "config", "user.email", "test@example.com")
    File.write(File.join(origin_dir, "README.md"), "# origin\n")
    system("git", "-C", origin_dir, "add", "README.md")
    system("git", "-C", origin_dir, "commit", "-q", "-m", "init")

    # Clone into repos/my-repo
    space    = create_real_space(dir)
    repo_dir = File.join(dir, "repos", "my-repo")
    system("git", "clone", "-q", origin_dir, repo_dir)
    system("git", "-C", repo_dir, "config", "user.name", "Test Builder")
    system("git", "-C", repo_dir, "config", "user.email", "test@example.com")
    space.data["repos"] = [{ "name" => "my-repo" }]

    project = Space::Architect::ArchitectProject.new(space: space)

    # (b) up-to-date: local and origin in sync
    results = project.sync_repos
    assert_equal 1, results.size
    assert_equal :up_to_date, results.first[:status]
    assert_match(/up to date/, results.first[:message])

    # (a) behind: add a commit to origin, then sync → fast-forwarded
    File.write(File.join(origin_dir, "v2.txt"), "v2\n")
    system("git", "-C", origin_dir, "add", "v2.txt")
    system("git", "-C", origin_dir, "commit", "-q", "-m", "v2")

    results = project.sync_repos
    assert_equal 1, results.size
    assert_equal :fast_forwarded, results.first[:status]
    assert_match(/fast-forwarded 1 commit/, results.first[:message])

    # Verify the local ref actually moved to match origin
    local_sha,  = Open3.capture3("git", "-C", repo_dir, "rev-parse", "HEAD")
    origin_sha, = Open3.capture3("git", "-C", origin_dir, "rev-parse", "HEAD")
    assert_equal origin_sha.strip, local_sha.strip

    # (c) dirty: stage a change, then try to sync — must be refused
    File.write(File.join(origin_dir, "v3.txt"), "v3\n")
    system("git", "-C", origin_dir, "add", "v3.txt")
    system("git", "-C", origin_dir, "commit", "-q", "-m", "v3")

    File.write(File.join(repo_dir, "staged.txt"), "staged\n")
    system("git", "-C", repo_dir, "add", "staged.txt")

    ref_before, = Open3.capture3("git", "-C", repo_dir, "rev-parse", "HEAD")
    results = project.sync_repos
    assert_equal :dirty, results.first[:status]
    ref_after, = Open3.capture3("git", "-C", repo_dir, "rev-parse", "HEAD")
    assert_equal ref_before.strip, ref_after.strip, "dirty: ref must be unchanged"

    # Unstage + remove so we can continue
    system("git", "-C", repo_dir, "reset", "--", "staged.txt", out: File::NULL, err: File::NULL)
    File.delete(File.join(repo_dir, "staged.txt"))

    # (c) diverged: make a local commit not on origin → non-fast-forwardable, must be refused
    File.write(File.join(repo_dir, "local_only.txt"), "local\n")
    system("git", "-C", repo_dir, "add", "local_only.txt")
    system("git", "-C", repo_dir, "commit", "-q", "-m", "local-only")

    ref_before, = Open3.capture3("git", "-C", repo_dir, "rev-parse", "HEAD")
    results = project.sync_repos
    assert_equal :diverged, results.first[:status]
    assert_match(/not fast-forwardable/, results.first[:message])
    ref_after, = Open3.capture3("git", "-C", repo_dir, "rev-parse", "HEAD")
    assert_equal ref_before.strip, ref_after.strip, "diverged: ref must be unchanged"

    # (single-repo) sync with an explicit name syncs only that repo
    results = project.sync_repos(repo_name: "my-repo")
    assert_equal 1, results.size

    # (single-repo) sync with an unknown name raises
    assert_raises(Space::Core::Error) { project.sync_repos(repo_name: "no-such-repo") }
  ensure
    FileUtils.rm_rf(dir)
    FileUtils.rm_rf(origin_dir)
  end

  # AC2: ground emits a staleness warning when a tracked repo is behind origin,
  #      is silent when up-to-date, and preserves existing ordering + worktree guard.
  def test_ground_warns_stale_repo
    dir        = Dir.mktmpdir("architect-ground-warn-test")
    origin_dir = Dir.mktmpdir("architect-ground-warn-origin-test")

    # Set up local "origin"
    system("git", "-C", origin_dir, "init", "-q", "-b", "main", exception: false) ||
      system("git", "-C", origin_dir, "init", "-q")
    system("git", "-C", origin_dir, "config", "user.name", "Test Builder")
    system("git", "-C", origin_dir, "config", "user.email", "test@example.com")
    File.write(File.join(origin_dir, "README.md"), "# origin\n")
    system("git", "-C", origin_dir, "add", "README.md")
    system("git", "-C", origin_dir, "commit", "-q", "-m", "init")

    # Clone into repos/my-repo
    space    = create_real_space(dir)
    repo_dir = File.join(dir, "repos", "my-repo")
    system("git", "clone", "-q", origin_dir, repo_dir)

    # Track the repo in space
    space.data["repos"] = [{ "name" => "my-repo" }]

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!

    # (b) up-to-date: no warning expected
    result = project.ground(session_cwd: dir)
    refute_match(/WARNING.*my-repo/, result, "no warning expected when repo is up-to-date")

    # Add a commit to origin so local is now behind
    File.write(File.join(origin_dir, "extra.txt"), "extra\n")
    system("git", "-C", origin_dir, "add", "extra.txt")
    system("git", "-C", origin_dir, "commit", "-q", "-m", "extra commit")

    # (a) stale: warning expected
    result = project.ground(session_cwd: dir)
    assert_match(/WARNING: repos\/my-repo.*behind.*origin\//, result)
    assert_match(/architect sync my-repo/, result)

    # Worktree guard still intact: builder wt → empty
    wt_cwd = File.join(dir, "build", "I01-some-slice-lane-a", "wt")
    assert_equal "", project.ground(session_cwd: wt_cwd)

    # Existing ordering intact: ARCHITECT.md before BRIEF.md
    project.brief_new!
    result2 = project.ground(session_cwd: dir)
    architect_idx = result2.index("ARCHITECT.md")
    brief_idx     = result2.index("BRIEF.md")
    assert architect_idx < brief_idx, "ARCHITECT.md must precede BRIEF.md even with staleness warning"
  ensure
    FileUtils.rm_rf(dir)
    FileUtils.rm_rf(origin_dir)
  end

  # ── I06: freeze --force, section --force, merge --into / --commit-mode ───────

  # AC1(a): freeze_force — re-freezes changed frozen region pre-dispatch and updates freeze_sha
  def test_freeze_force_refreezes_changed_frozen_region_pre_dispatch
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    freeze_sha_1 = project.freeze!("my-slice")

    # Amend the frozen region (Grounds is above ## Builder Prompt)
    slice = File.join(dir, "architecture", "I01-my-slice.md")
    text = File.read(slice)
    File.write(slice, text.sub("## Grounds", "## Grounds\n\nAmended grounds for re-freeze."))

    freeze_sha_2 = project.freeze!("my-slice", force: true)

    refute_equal freeze_sha_1, freeze_sha_2, "force re-freeze must produce a new sha"

    yml = YAML.safe_load(File.read(File.join(dir, "space.yaml")), aliases: false)
    assert_equal freeze_sha_2, yml.dig("project", "iterations", 0, "freeze_sha"),
      "space.yaml must record the new freeze_sha after force re-freeze"

    status, = Open3.capture3("git", "-C", dir, "status", "--porcelain")
    assert_equal "", status.strip, "workspace must be clean after force re-freeze"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC1(b): freeze_force — refuses post-dispatch (dispatched_at set)
  def test_freeze_force_refuses_if_lane_dispatched
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")
    project.freeze!("my-slice")

    # Simulate dispatch
    space.data.dig("project", "iterations").find { |s| s["name"] == "my-slice" }
      .dig("lanes").find { |l| l["name"] == "lane-a" }["dispatched_at"] = "2026-01-01T00:00:00Z"

    slice = File.join(dir, "architecture", "I01-my-slice.md")
    text = File.read(slice)
    File.write(slice, text.sub("## Grounds", "## Grounds\n\nTamper attempt."))

    err = assert_raises(Space::Core::Error) do
      project.freeze!("my-slice", force: true)
    end
    assert_match(/lane-a/, err.message)
    assert_match(/dispatched/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC1(c): freeze_force — without --force, changed frozen region still raises (existing behavior)
  def test_freeze_force_without_flag_refuses_changed_region
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")

    slice = File.join(dir, "architecture", "I01-my-slice.md")
    text = File.read(slice)
    File.write(slice, text.sub("## Grounds", "## Grounds\n\nChanged."))

    err = assert_raises(Space::Core::Error) do
      project.freeze!("my-slice")
    end
    assert_match(/refusing to re-freeze/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2(a): section_force — writes a frozen section pre-dispatch
  def test_section_force_writes_frozen_section_pre_dispatch
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")

    res = project.write_section!("my-slice", "specification", body: "Amended spec.", force: true)
    assert res[:committed]

    text = File.read(File.join(dir, "architecture", "I01-my-slice.md"))
    assert_match(/Amended spec\./, text)
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2(b): section_force — refuses post-dispatch (integrate_sha set)
  def test_section_force_refuses_if_lane_dispatched
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")
    project.freeze!("my-slice")

    # Simulate post-integrate via integrate_sha
    space.data.dig("project", "iterations").find { |s| s["name"] == "my-slice" }
      .dig("lanes").find { |l| l["name"] == "lane-a" }["integrate_sha"] = "abc123def456"

    err = assert_raises(Space::Core::Error) do
      project.write_section!("my-slice", "specification", body: "Tampered spec.", force: true)
    end
    assert_match(/lane-a/, err.message)
    assert_match(/dispatched/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2(c): section_force — without --force, frozen section still raises (existing behavior)
  def test_section_force_without_flag_refuses_frozen_section
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")

    err = assert_raises(Space::Core::Error) do
      project.write_section!("my-slice", "specification", body: "Tampered spec.")
    end
    assert_match(/frozen/i, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC3(a): merge_into — merges into the named branch instead of project/<slug>
  def test_merge_into_uses_named_branch
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

    r = project.merge_lane!("my-slice", "lane-a", into: "custom/target-branch")

    assert_equal "custom/target-branch", r[:integration_branch]

    repo = File.join(dir, "repos", "my-repo")
    assert_path_exists File.join(repo, ".git", "refs", "heads", "custom", "target-branch"),
      "custom/target-branch must exist in the repo after merge"
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── I07: worktree_add --force / provision --force / worktree add --force ──────

  # AC1(a): force: true clears a stale (unregistered) dir and creates a registered worktree.
  def test_worktree_force_clears_stale_dir_and_creates_registered_worktree
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    stray_dir = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    FileUtils.mkdir_p(stray_dir)
    File.write(File.join(stray_dir, "stale.txt"), "leftover\n")

    result = project.worktree_add("my-repo", "my-slice", "lane-a", force: true)

    assert_path_exists result[:worktree].to_s
    refute File.exist?(File.join(stray_dir, "stale.txt")), "stale file must be gone after force clear"
    repo_path = Pathname.new(File.join(dir, "repos", "my-repo"))
    assert project.send(:worktree_registered?, repo_path, result[:worktree]),
      "worktree must be registered after force add"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC1(b): no force → raises the existing error on stale dir (with --force hint).
  def test_worktree_force_raises_without_force_on_stale_dir
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    stray_dir = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    FileUtils.mkdir_p(stray_dir)

    err = assert_raises(Space::Core::Error) do
      project.worktree_add("my-repo", "my-slice", "lane-a")
    end
    assert_match(/exists but is not a registered git worktree/, err.message)
    assert_match(/resolve manually/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC1(c): force: true on an already-registered worktree → idempotent skip, no rm -rf.
  def test_worktree_force_skips_already_registered_worktree
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    project.worktree_add("my-repo", "my-slice", "lane-a")
    sentinel = File.join(dir, "build", "I01-my-slice-lane-a", "wt", "sentinel.txt")
    File.write(sentinel, "keep me\n")

    project.worktree_add("my-repo", "my-slice", "lane-a", force: true)

    assert File.exist?(sentinel), "sentinel must survive — registered worktree must not be rm -rf'd by --force"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2(a): provision --force recovers a stale lane worktree (returns created: true).
  def test_provision_force_recovers_stale_lane_worktree
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    write_iteration_with_lanes(dir, "my-slice", <<~YAML)
      - name: lane-a
        repo: my-repo
        touch:
          - lib/**
    YAML
    project.freeze!("my-slice")

    stray_dir = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    FileUtils.mkdir_p(stray_dir)

    results = project.provision("my-slice", force: true)
    assert_equal 1, results.length
    assert results[0][:created], "force provision must create the worktree (created: true)"
    assert_path_exists results[0][:worktree].to_s
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC2(b): provision without --force raises on a stale lane worktree.
  def test_provision_force_raises_without_force_on_stale_lane
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    write_iteration_with_lanes(dir, "my-slice", <<~YAML)
      - name: lane-a
        repo: my-repo
        touch:
          - lib/**
    YAML
    project.freeze!("my-slice")

    stray_dir = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    FileUtils.mkdir_p(stray_dir)

    err = assert_raises(Space::Core::Error) { project.provision("my-slice") }
    assert_match(/exists but is not a registered git worktree/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC3: worktree add --force (CLI) recovers a stale worktree.
  def test_worktree_add_force_cli_recovers_stale_worktree
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    stray_dir = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    FileUtils.mkdir_p(stray_dir)

    Dir.chdir(dir) do
      out, _err = invoke("worktree", "add", "my-repo", "my-slice", "lane-a", "--force")
      assert_match(/Worktree:/, out)
    end

    wt_path = Pathname.new(File.join(dir, "build", "I01-my-slice-lane-a", "wt"))
    repo_path = Pathname.new(File.join(dir, "repos", "my-repo"))
    assert_path_exists wt_path.to_s
    assert project.send(:worktree_registered?, repo_path, wt_path),
      "worktree must be registered after CLI --force add"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC4: ensure_lane_materialized stays non-force — a stale dir still raises.
  def test_ensure_lane_not_force_raises_on_stale_dir
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    write_iteration_with_lanes(dir, "my-slice", <<~YAML)
      - name: lane-a
        repo: my-repo
        touch:
          - lib/**
    YAML
    project.freeze!("my-slice")

    stray_dir = File.join(dir, "build", "I01-my-slice-lane-a", "wt")
    FileUtils.mkdir_p(stray_dir)

    err = assert_raises(Space::Core::Error) do
      project.send(:ensure_lane_materialized, "my-slice", "lane-a")
    end
    assert_match(/exists but is not a registered git worktree/, err.message)
    assert_path_exists stray_dir, "stale dir must NOT be removed — ensure_lane_materialized is non-force"
  ensure
    FileUtils.rm_rf(dir)
  end

  # AC3(b): merge_commit_mode — conductor mode treats canonical conductor commits as non-builder
  def test_merge_commit_mode_conductor_passes_canonical_commit
    dir = Dir.mktmpdir("architect-project-test")
    space = create_real_space(dir)
    create_real_repo(dir, "my-repo")

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")
    project.freeze!("my-slice")
    project.worktree_add("my-repo", "my-slice", "lane-a")

    wt = File.join(dir, "build", "I01-my-slice-lane-a", "wt")

    # Make a canonical conductor commit
    File.write(File.join(wt, "work.rb"), "x = 1\n")
    system("git", "-C", wt, "add", "work.rb", out: File::NULL, err: File::NULL)
    system("git", "-C", wt, "commit", "-q", "-m", "I01-my-slice-lane-a: builder output")

    # Without conductor mode this raises "builder commits"
    File.write(File.join(wt, "more.rb"), "y = 2\n")
    err = assert_raises(Space::Core::Error) { project.merge_lane!("my-slice", "lane-a") }
    assert_match(/builder commits/i, err.message)

    # With conductor mode the canonical commit is excluded; merge succeeds
    r = project.merge_lane!("my-slice", "lane-a", commit_mode: "conductor")
    assert_equal false, r[:gates_run]
    assert_match(/\Aproject\//, r[:integration_branch])
  ensure
    FileUtils.rm_rf(dir)
  end
end

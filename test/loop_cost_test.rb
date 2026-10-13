# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"
require "fileutils"
require "open3"

# Public-interface tests for `architect cost` (Space::Architect::LoopCost).
# Every case drives the CLI via invoke() over a tmp copy of the synthetic
# fixture tree in test/fixtures/loop_cost/ — the live pi sessions corpus is
# never a fixture. Expected numbers are hand-computed from the fixture files.
class LoopCostTest < Space::ArchitectTest
  FIXTURE = Pathname.new(__dir__).join("fixtures/loop_cost")
  FIXTURE_SLUG = "--Fix-Ture--"

  def setup
    @space_dir = Dir.mktmpdir("loop-cost-space")
    seed_git_repo(@space_dir)
    File.write(File.join(@space_dir, "space.yaml"), File.read(FIXTURE.join("space.yaml")))
    @root = Dir.mktmpdir("loop-cost-sessions")
    FileUtils.cp_r(FIXTURE.join(FIXTURE_SLUG), File.join(@root, Space::Architect::LoopCost.slug_dir(@space_dir)))
  end

  def teardown
    FileUtils.remove_entry(@space_dir) if @space_dir
    FileUtils.remove_entry(@root) if @root
  end

  def test_slug_dir_matches_the_live_pi_naming_rule
    assert_equal "--Users-eric--", Space::Architect::LoopCost.slug_dir("/Users/eric")
    assert_equal "--Users-eric-architect-spaces-20261009-pi-port--",
      Space::Architect::LoopCost.slug_dir("/Users/eric/architect/spaces/20261009-pi-port")
  end

  def test_default_view_aggregates_runs_and_sessions_with_totals_and_hit_ratio
    report = cost_json
    assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
    # broken_meta.json is malformed and drops out; noise.jsonl and
    # broken_session.jsonl carry no type:session header, so 4 + 4 parsed.
    assert_equal 4, report["runs"]
    assert_equal 4, report["sessions"]

    worker = row(report, "worker", "zai/glm-5.3-flash")
    assert_equal({"agent" => "worker", "model" => "zai/glm-5.3-flash", "runs" => 1, "input" => 10,
      "output" => 5, "cache_read" => 100, "cache_write" => 0, "cost" => 0.01, "turns" => 2,
      "cache_hit_ratio" => 100 / 110.0}, worker)

    session = row(report, "(session)", "zai/glm-5.3-flash")
    assert_equal 3, session["runs"] # s1 + runner session.jsonl + truncated_session
    assert_equal 3, session["turns"] # one round in each of those files
    assert_in_delta 0.11, session["cost"], 1e-9

    totals = report["totals"]
    assert_equal 9, totals["runs"]
    assert_equal 48, totals["input"]
    assert_equal 108, totals["cache_read"]
    assert_in_delta 0.21, totals["cost"], 1e-9
    assert_equal 16, totals["turns"]
    assert_in_delta 108 / 156.0, totals["cache_hit_ratio"], 1e-9
  end

  def test_model_keys_fold_thinking_suffixes_and_fall_back_to_model
    models = cost_json["rows"].map { |r| r["model"] }
    # r2 has no requestedModel → model "zai/glm-5.3:high" folds to the bare key.
    assert_includes models, "zai/glm-5.3"
    # r3's requestedModel itself carries ":high"; r4 sits three dirs deep.
    assert_includes models, "zai/glm-5.3-flash"
    assert_includes models, "fireworks/accounts/fireworks/models/glm-5p3-flash"
    assert models.none? { |m| m.include?(":") }
  end

  def test_session_costs_accept_hash_and_float_shapes
    report = cost_json
    # hash {total: 0.03} ×3 vs float 0.04
    assert_in_delta 0.11, row(report, "(session)", "zai/glm-5.3-flash")["cost"], 1e-9
    assert_in_delta 0.04, row(report, "(session)", "zai/glm-5.3")["cost"], 1e-9
  end

  def test_by_iteration_buckets_by_rehearsal_boundaries_with_unattributed
    report = cost_json("--by-iteration")
    assert_equal ["first", "second", "unattributed"], report["iterations"].map { |i| i["name"] }
    assert_equal "2020-03-01T00:00:00Z", report["iterations"][0]["starts_at"]
    assert_equal "2020-06-01T00:00:00Z", report["iterations"][1]["starts_at"]
    assert_nil report["iterations"][2]["starts_at"]

    # r2 (2020-01-15) predates the first boundary; the open last window
    # (>= 2020-06-01) takes the three August session files — s1 lands in two
    # model rows (flash + bare), so the file count is per row, not a sum.
    assert_equal ["architect-spec"], report["iterations"][2]["rows"].map { |r| r["agent"] }
    assert_equal({ "zai/glm-5.3-flash" => 2, "zai/glm-5.3" => 1, "test/model" => 1 },
      report["iterations"][1]["rows"].select { |r| r["agent"] == "(session)" }.to_h { |r| [r["model"], r["runs"]] })
    assert_in_delta 0.02, report["iterations"][2]["totals"]["cost"], 1e-9
    assert_in_delta 0.07, report["iterations"][0]["totals"]["cost"], 1e-9
    assert_in_delta 0.12, report["iterations"][1]["totals"]["cost"], 1e-9

    sum = report["iterations"].sum { |i| i["totals"]["cost"] }
    assert_in_delta report["grand_total"]["cost"], sum, 1e-9
    assert_in_delta 0.21, report["grand_total"]["cost"], 1e-9
  end

  def test_by_iteration_git_commit_time_beats_rehearsal
    space = Dir.mktmpdir("loop-cost-git-space")
    root = nil
    seed_git_repo(space)
    yaml = File.read(FIXTURE.join("space.yaml")).sub('at: "2020-03-01T00:00:00Z"', 'at: "2020-05-01T00:00:00Z"')
    File.write(File.join(space, "space.yaml"), yaml)
    dates = {"GIT_AUTHOR_DATE" => "2020-03-01T00:00:00+00:00", "GIT_COMMITTER_DATE" => "2020-03-01T00:00:00+00:00"}
    system(dates, "git", "-C", space, "add", "space.yaml", exception: true)
    system(dates, "git", "-C", space, "commit", "-q", "-m", "freeze", exception: true)
    sha = Open3.capture2("git", "-C", space, "rev-parse", "HEAD")[0].strip
    File.write(File.join(space, "space.yaml"),
      yaml.sub("      file: architecture/I01-first.md\n", "      file: architecture/I01-first.md\n      freeze_sha: #{sha}\n"))

    root = Dir.mktmpdir("loop-cost-git-sessions")
    FileUtils.cp_r(FIXTURE.join(FIXTURE_SLUG), File.join(root, Space::Architect::LoopCost.slug_dir(space)))
    out, = invoke("cost", "--space", space, "--sessions-root", root, "--json", "--by-iteration")
    report = JSON.parse(out)
    # The freeze_sha commit (2020-03-01) is the boundary even though
    # rehearsal.at says 2020-05-01.
    assert_equal "2020-03-01T00:00:00Z", report["iterations"][0]["starts_at"]
    assert_equal ["first", "second", "unattributed"], report["iterations"].map { |i| i["name"] }
  ensure
    FileUtils.remove_entry(space) if space
    FileUtils.remove_entry(root) if root
  end

  def test_latency_measures_rounds_wall_and_tokens_across_the_corpus
    lat = cost_json("--latency")["latency"].to_h { |m| [m["model"], m] }
    # r1's transcript (2 rounds, 16s, 30 out) + s1 (5s, 2) + runner session
    # (4s, 2) + truncated_session (1s, 7).
    flash = lat.fetch("zai/glm-5.3-flash")
    assert_equal 5, flash["rounds"]
    assert_in_delta 26.0, flash["wall_s"], 1e-9
    assert_equal 41, flash["output_tokens"]
    assert_in_delta 26.0 / 5, flash["mean_wall_s"], 1e-9
    assert_in_delta 41 / 26.0, flash["output_toks_per_s"], 1e-9

    bare = lat.fetch("zai/glm-5.3") # s1's second round: 10s, 6 out
    assert_equal 1, bare["rounds"]
    assert_in_delta 10.0, bare["wall_s"], 1e-9
    assert_in_delta 10.0, bare["mean_wall_s"], 1e-9
    assert_in_delta 0.6, bare["output_toks_per_s"], 1e-9

    # s2's first round is zero-wall (same millisecond): it counts as a round,
    # adds 0 s, and the tok/s denominator is total wall, never round count.
    zero = lat.fetch("test/model")
    assert_equal 2, zero["rounds"]
    assert_in_delta 5.0, zero["wall_s"], 1e-9
    assert_in_delta 2.5, zero["mean_wall_s"], 1e-9
    assert_in_delta 2.0, zero["output_toks_per_s"], 1e-9

    # The orphan transcript joins no meta → its own record model + timestamps.
    orphan = lat.fetch("unknown/model")
    assert_equal 1, orphan["rounds"]
    assert_in_delta 2.0, orphan["wall_s"], 1e-9
    assert_equal 4, orphan["output_tokens"]
  end

  def test_since_filters_runs_and_sessions_and_rejects_garbage
    report = cost_json("--since", "2020-04-01")
    assert_equal "2020-04-01", report["since"]
    assert_equal 3, report["runs"] # r2 (2020-01-15) dropped
    assert_equal 4, report["sessions"]
    assert_equal 8, report["totals"]["runs"]
    assert_in_delta 0.19, report["totals"]["cost"], 1e-9

    _, err = invoke("cost", "--space", @space_dir, "--sessions-root", @root, "--since", "not-a-date")
    assert_equal 1, Space::Architect::CLI.last_outcome&.exit_code
    assert_includes err, "not-a-date"
  end

  def test_json_contract_keys_are_frozen
    report = cost_json
    assert_equal %w[rows runs sessions sessions_root since slug_dir space totals], report.keys.sort
    assert_equal "cost-fixture", report["space"]
    assert_equal Space::Architect::LoopCost.slug_dir(@space_dir), report["slug_dir"]
    assert_nil report["since"]
    row_keys = %w[agent cache_hit_ratio cache_read cache_write cost input model output runs turns]
    assert_equal row_keys, report["rows"].first.keys.sort
    assert_equal row_keys - %w[agent model], report["totals"].keys.sort

    iterated = cost_json("--by-iteration")
    assert_equal %w[grand_total iterations rows runs sessions sessions_root since slug_dir space totals], iterated.keys.sort
    assert_equal %w[name rows starts_at totals], iterated["iterations"].first.keys.sort

    latency = cost_json("--latency")
    assert_equal %w[latency rows runs sessions sessions_root since slug_dir space totals], latency.keys.sort
    assert_equal %w[mean_wall_s model output_tokens output_toks_per_s rounds wall_s],
      latency["latency"].first.keys.sort
  end

  def test_default_text_view_renders_the_table_with_a_totals_row
    out, = invoke("cost", "--space", @space_dir, "--sessions-root", @root)
    assert_includes out, "Hit%"
    assert_includes out, "(session)"
    assert_includes out, "TOTAL"
    assert_includes out, "0.2100"
  end

  def test_missing_slug_dir_fails_loud_naming_the_expected_path
    empty_root = Dir.mktmpdir("loop-cost-empty")
    out, err = invoke("cost", "--space", @space_dir, "--sessions-root", empty_root)
    assert_equal 1, Space::Architect::CLI.last_outcome&.exit_code
    assert_includes err, Space::Architect::LoopCost.slug_dir(@space_dir)
    assert_empty out
  ensure
    FileUtils.remove_entry(empty_root)
  end

  def test_by_iteration_and_latency_together_is_a_loud_error
    out, err = invoke("cost", "--space", @space_dir, "--sessions-root", @root, "--by-iteration", "--latency")
    assert_equal 1, Space::Architect::CLI.last_outcome&.exit_code
    assert_includes err, "mutually exclusive"
    assert_empty out
  end

  private

  def cost_json(*extra)
    out, err = invoke("cost", "--space", @space_dir, "--sessions-root", @root, "--json", *extra)
    assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code, err
    JSON.parse(out)
  end

  def row(report, agent, model)
    report["rows"].find { |r| r["agent"] == agent && r["model"] == model }
  end
end

# frozen_string_literal: true

require_relative "../action_test_helper"

class SpacesShowI03Test < Minitest::Test
  include ActionTestHelper

  ITERATION_MARKDOWN = <<~MD
    # I01: Test Iteration

    ## Grounds

    The grounds content.

    ## Specification

    The specification content.

    ## Acceptance Criteria

    - AC-1: First criterion

    ## Builder Prompt

    Build this.

    ## Builder Report

    Done building.

    ## Verdict

    continue
  MD

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "i03-show-owner-uid", username: "i03-show-owner"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # ── decisions ────────────────────────────────────────────────────────────────

  def test_show_includes_decisions_for_iteration_artifact
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "decisions-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "iteration", path: "architecture/I01.md", title: "I01",
            raw: ITERATION_MARKDOWN]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iteration = parse_json(body)["props"]["iterations"].first

    assert iteration.key?("decisions"), "must include decisions key"
    assert_kind_of Array, iteration["decisions"]
    assert iteration["decisions"].length > 0, "must have at least one decision"
  end

  def test_show_decisions_canonical_order
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "order-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "iteration", path: "architecture/I01.md", title: "I01",
            raw: ITERATION_MARKDOWN]

    _, _, body = inertia_get("/spaces/#{space.id}")
    decisions = parse_json(body)["props"]["iterations"].first["decisions"]

    names = decisions.map { |d| d["name"] }
    canonical = ["Grounds", "Specification", "Acceptance Criteria",
                 "Builder Prompt", "Builder Report", "Verdict"]
    assert_equal canonical & names, names,
      "decisions must appear in canonical order"
  end

  def test_show_decisions_include_body_content
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "body-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "iteration", path: "architecture/I01.md", title: "I01",
            raw: ITERATION_MARKDOWN]

    _, _, body = inertia_get("/spaces/#{space.id}")
    decisions = parse_json(body)["props"]["iterations"].first["decisions"]

    grounds = decisions.find { |d| d["name"] == "Grounds" }
    refute_nil grounds, "Grounds decision must be present"
    assert_match "grounds content", grounds["body"],
      "body must contain section markdown"
  end

  def test_show_decisions_omits_absent_sections
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "partial-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    # Only Grounds + Verdict sections present
    partial_md = "## Grounds\n\nSome grounds.\n\n## Verdict\n\ncontinue\n"
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "iteration", path: "architecture/I01.md", title: "I01",
            raw: partial_md]

    _, _, body = inertia_get("/spaces/#{space.id}")
    decisions = parse_json(body)["props"]["iterations"].first["decisions"]

    names = decisions.map { |d| d["name"] }
    assert_includes names, "Grounds"
    assert_includes names, "Verdict"
    refute_includes names, "Specification"
    refute_includes names, "Builder Prompt"
  end

  def test_show_decisions_empty_when_no_iteration_artifact
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "no-art-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    # Only a non-iteration artifact
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "lane_report", path: "build/I01/report.md", title: "Report",
            raw: "Report content."]

    _, _, body = inertia_get("/spaces/#{space.id}")
    decisions = parse_json(body)["props"]["iterations"].first["decisions"]

    assert_equal [], decisions
  end

  # ── content fidelity (nested ## subsections) ─────────────────────────────────

  NESTED_ITERATION_MARKDOWN = <<~MD
    # I01: Real Iteration

    ## Grounds

    The grounds content.

    ## Specification

    Top-level spec intro.

    ## Objective

    The nested objective subsection.

    ## Boundaries

    The nested boundaries subsection.

    ## Acceptance Criteria

    - AC-1: criterion

    ## Builder Prompt

    Build this.

    ## Verdict

    continue
  MD

  def test_show_decisions_specification_body_includes_nested_subsections
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "nested-spec-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-nested"]
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "iteration", path: "architecture/I01-nested.md", title: "I01 Nested",
            raw: NESTED_ITERATION_MARKDOWN]

    _, _, body = inertia_get("/spaces/#{space.id}")
    decisions = parse_json(body)["props"]["iterations"].first["decisions"]

    spec = decisions.find { |d| d["name"] == "Specification" }
    refute_nil spec, "Specification decision must be present"
    assert_match "Top-level spec intro",           spec["body"]
    assert_match "## Objective",                   spec["body"],
      "nested ## Objective header must be preserved in Specification body"
    assert_match "The nested objective subsection", spec["body"],
      "nested Objective content must be in Specification body"
    assert_match "## Boundaries",                  spec["body"],
      "nested ## Boundaries header must be preserved in Specification body"

    # Nested non-canonical headers must NOT become top-level decisions
    names = decisions.map { |d| d["name"] }
    refute_includes names, "Objective",  "Objective must not be its own decision"
    refute_includes names, "Boundaries", "Boundaries must not be its own decision"

    # Canonical order preserved
    canonical = ["Grounds", "Specification", "Acceptance Criteria",
                 "Builder Prompt", "Builder Report", "Verdict"]
    assert_equal canonical & names, names, "decisions must be in canonical order"
  end

  # ── created_at ───────────────────────────────────────────────────────────────

  def test_show_iteration_includes_created_at
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "ts-iter-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iteration = parse_json(body)["props"]["iterations"].first

    assert iteration.key?("created_at"), "iteration must include created_at"
    refute_nil iteration["created_at"]
    # Must be parseable as iso8601
    assert Time.iso8601(iteration["created_at"])
  end

  def test_show_run_includes_created_at
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "ts-run-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    Factory[:run, user_id: @owner.id, space_id: space.id,
            iteration_id: iter.id, role: "builder", lane: "lane-a"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    run_data = parse_json(body)["props"]["iterations"].first["runs"].first

    assert run_data.key?("created_at"), "run must include created_at"
    assert Time.iso8601(run_data["created_at"])
  end

  def test_show_unassigned_run_includes_created_at
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "ts-unassigned-space"]
    Factory[:run, user_id: @owner.id, space_id: space.id,
            iteration_id: nil, role: "builder", lane: "lane-a"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    run_data = parse_json(body)["props"]["unassigned_runs"].first

    assert run_data.key?("created_at"), "unassigned run must include created_at"
    assert Time.iso8601(run_data["created_at"])
  end

  # ── architect_runs ────────────────────────────────────────────────────────────

  def test_show_includes_architect_runs_prop
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "arch-runs-space"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    props = parse_json(body)["props"]

    assert props.key?("architect_runs"), "props must include architect_runs"
    assert_kind_of Array, props["architect_runs"]
  end

  def test_show_architect_run_in_architect_runs
    sign_in(@owner)
    space     = Factory[:space, user_id: @owner.id, slug: "arch-run-space"]
    arch_run  = Factory[:run, user_id: @owner.id, space_id: space.id,
                        iteration_id: nil, role: "architect",
                        session_id: "sess-abc-123"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    props      = parse_json(body)["props"]
    arch_runs  = props["architect_runs"]

    assert_equal 1, arch_runs.length
    assert_equal arch_run.id, arch_runs.first["id"]
    assert_equal "architect",   arch_runs.first["role"]
    assert arch_runs.first.key?("session_id"), "architect_run must include session_id"
    assert arch_runs.first.key?("created_at"), "architect_run must include created_at"
    assert arch_runs.first.key?("conversation_id"), "architect_run must include conversation_id"
  end

  def test_show_architect_run_excluded_from_unassigned_runs
    sign_in(@owner)
    space    = Factory[:space, user_id: @owner.id, slug: "excl-arch-space"]
    Factory[:run, user_id: @owner.id, space_id: space.id,
            iteration_id: nil, role: "architect", session_id: "sess-xyz"]

    _, _, body      = inertia_get("/spaces/#{space.id}")
    unassigned_runs = parse_json(body)["props"]["unassigned_runs"]

    assert_equal [], unassigned_runs,
      "architect runs must not appear in unassigned_runs"
  end

  def test_show_non_architect_orphan_in_unassigned_runs
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "mixed-orphan-space"]
    builder_run = Factory[:run, user_id: @owner.id, space_id: space.id,
                          iteration_id: nil, role: "builder", lane: "lane-b"]
    Factory[:run, user_id: @owner.id, space_id: space.id,
            iteration_id: nil, role: "architect"]

    _, _, body      = inertia_get("/spaces/#{space.id}")
    props           = parse_json(body)["props"]
    unassigned_runs = props["unassigned_runs"]
    architect_runs  = props["architect_runs"]

    assert_equal 1, unassigned_runs.length, "only non-architect orphan in unassigned_runs"
    assert_equal builder_run.id, unassigned_runs.first["id"]
    assert_equal 1, architect_runs.length, "only architect orphan in architect_runs"
  end

  def test_show_architect_runs_ordered_by_created_at_asc
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "arch-order-space"]
    t1 = Time.now - 100
    t2 = Time.now - 50
    run_a = Factory[:run, user_id: @owner.id, space_id: space.id,
                    iteration_id: nil, role: "architect", created_at: t1, updated_at: t1]
    run_b = Factory[:run, user_id: @owner.id, space_id: space.id,
                    iteration_id: nil, role: "architect", created_at: t2, updated_at: t2]

    _, _, body = inertia_get("/spaces/#{space.id}")
    arch_runs  = parse_json(body)["props"]["architect_runs"]

    ids = arch_runs.map { |r| r["id"] }
    assert_equal [run_a.id, run_b.id], ids,
      "architect_runs must be ordered by created_at asc"
  end

  # ── occurred_at and has_transcript on architect_run_props ────────────────────

  def test_show_architect_run_includes_occurred_at_and_has_transcript
    sign_in(@owner)
    space   = Factory[:space, user_id: @owner.id, slug: "arch-occurred-space"]
    arch_run = Factory[:run, user_id: @owner.id, space_id: space.id,
                       iteration_id: nil, role: "architect", session_id: "sess-occ-1"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    r = parse_json(body)["props"]["architect_runs"].first

    assert r.key?("occurred_at"),    "architect_run must include occurred_at"
    assert r.key?("has_transcript"), "architect_run must include has_transcript"
  end

  def test_show_architect_run_has_transcript_false_when_no_conversation
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "arch-no-conv-space"]
    Factory[:run, user_id: @owner.id, space_id: space.id,
            iteration_id: nil, role: "architect", conversation_id: nil]

    _, _, body = inertia_get("/spaces/#{space.id}")
    r = parse_json(body)["props"]["architect_runs"].first

    assert_equal false, r["has_transcript"]
    assert_nil r["occurred_at"]
  end

  def test_show_architect_run_has_transcript_true_when_conversation_present
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "arch-conv-space"]
    conv  = Factory[:conversation, user_id: @owner.id]
    Factory[:run, user_id: @owner.id, space_id: space.id,
            iteration_id: nil, role: "architect", conversation_id: conv.id]

    _, _, body = inertia_get("/spaces/#{space.id}")
    r = parse_json(body)["props"]["architect_runs"].first

    assert_equal true, r["has_transcript"]
  end

  # ── occurred_at on iterations ─────────────────────────────────────────────────

  def test_show_iteration_includes_occurred_at_key
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-occurred-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-occ"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    assert iter.key?("occurred_at"), "iteration must include occurred_at key"
  end

  def test_show_iteration_occurred_at_nil_by_default
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-nil-occurred-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-nil"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    # Factory creates without occurred_at; must serialize as null
    assert_nil iter["occurred_at"]
  end

  # ── microsecond precision (AC-3) ──────────────────────────────────────────────

  def test_show_iteration_created_at_microsecond_precision
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-micro-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-micro"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    assert_match(/T\d\d:\d\d:\d\d\.\d{6}/, iter["created_at"],
      "iteration created_at must have 6 fractional digits")
  end

  def test_show_iteration_occurred_at_microsecond_precision_when_present
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-occ-micro-space"]
    t = Time.parse("2026-06-28T15:32:12.278000Z").utc
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-occ-micro",
            occurred_at: t]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    assert_match(/T\d\d:\d\d:\d\d\.\d{6}/, iter["occurred_at"],
      "iteration occurred_at must have 6 fractional digits when present")
  end

  def test_show_architect_run_created_at_microsecond_precision
    sign_in(@owner)
    space    = Factory[:space, user_id: @owner.id, slug: "arch-micro-space"]
    Factory[:run, user_id: @owner.id, space_id: space.id,
            iteration_id: nil, role: "architect", session_id: "sess-micro-1"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    r = parse_json(body)["props"]["architect_runs"].first

    assert_match(/T\d\d:\d\d:\d\d\.\d{6}/, r["created_at"],
      "architect_run created_at must have 6 fractional digits")
  end

  def test_show_architect_run_occurred_at_microsecond_precision_when_present
    sign_in(@owner)
    space    = Factory[:space, user_id: @owner.id, slug: "arch-occ-micro-space"]
    t = Time.parse("2026-06-28T21:32:12.278000Z").utc
    Factory[:run, user_id: @owner.id, space_id: space.id,
            iteration_id: nil, role: "architect", session_id: "sess-micro-2",
            occurred_at: t]

    _, _, body = inertia_get("/spaces/#{space.id}")
    r = parse_json(body)["props"]["architect_runs"].first

    assert_match(/T\d\d:\d\d:\d\d\.\d{6}/, r["occurred_at"],
      "architect_run occurred_at must have 6 fractional digits when present")
  end

  def test_show_builder_run_created_at_microsecond_precision
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "run-micro-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-run-micro"]
    Factory[:run, user_id: @owner.id, space_id: space.id,
            iteration_id: iter.id, role: "builder", lane: "lane-a"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    r = parse_json(body)["props"]["iterations"].first["runs"].first

    assert_match(/T\d\d:\d\d:\d\d\.\d{6}/, r["created_at"],
      "builder run created_at must have 6 fractional digits")
  end

  # ── occurred_at_utc_offset on iterations (AC-3) ───────────────────────────────

  def test_show_iteration_includes_occurred_at_utc_offset_key
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-offset-key-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-offset-key"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    assert iter.key?("occurred_at_utc_offset"), "iteration must include occurred_at_utc_offset key"
  end

  def test_show_iteration_occurred_at_utc_offset_nil_by_default
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-offset-nil-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-offset-nil"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    assert_nil iter["occurred_at_utc_offset"]
  end

  def test_show_iteration_occurred_at_utc_offset_integer_when_set
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-offset-set-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-offset-set",
            occurred_at_utc_offset: -21600]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    assert_equal(-21600, iter["occurred_at_utc_offset"])
  end

  # ── git_utc_offset on space prop (AC-3) ───────────────────────────────────────

  def test_show_space_prop_includes_git_utc_offset_key
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "space-offset-key-space"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    space_prop = parse_json(body)["props"]["space"]

    assert space_prop.key?("git_utc_offset"), "space prop must include git_utc_offset key"
  end

  def test_show_space_prop_git_utc_offset_nil_by_default
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "space-offset-nil-space"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    space_prop = parse_json(body)["props"]["space"]

    assert_nil space_prop["git_utc_offset"]
  end

  def test_show_space_prop_git_utc_offset_integer_when_set
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "space-offset-set-space",
                    git_utc_offset: -21600]

    _, _, body = inertia_get("/spaces/#{space.id}")
    space_prop = parse_json(body)["props"]["space"]

    assert_equal(-21600, space_prop["git_utc_offset"])
  end
end

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
end

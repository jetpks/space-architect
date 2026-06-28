# frozen_string_literal: true

require_relative "action_test_helper"

class SpacesTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "spaces-owner-uid", username: "spaces-owner"]
    @other = Factory[:user, github_uid: "spaces-other-uid", username: "spaces-other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # ── Index ────────────────────────────────────────────────────────────────────

  def test_index_returns_200
    status, _, _ = inertia_get("/spaces")
    assert_equal 200, status
  end

  def test_index_renders_spaces_index_component
    _, _, body = inertia_get("/spaces")
    assert_equal "Spaces/Index", parse_json(body)["component"]
  end

  def test_index_returns_empty_spaces_for_anon
    Factory[:space, user_id: @owner.id]
    _, _, body = inertia_get("/spaces")
    assert_equal [], parse_json(body)["props"]["spaces"]
  end

  def test_index_returns_own_spaces_when_signed_in
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "my-space", title: "My Space", status: "active"]
    _, _, body = inertia_get("/spaces")
    spaces = parse_json(body)["props"]["spaces"]
    assert_equal 1, spaces.length
    assert_equal space.id,   spaces.first["id"]
    assert_equal "my-space", spaces.first["slug"]
    assert_equal "My Space", spaces.first["title"]
  end

  def test_index_does_not_return_other_users_spaces
    sign_in(@owner)
    Factory[:space, user_id: @other.id, slug: "other-space"]
    _, _, body = inertia_get("/spaces")
    assert_equal [], parse_json(body)["props"]["spaces"]
  end

  def test_index_space_props_include_required_keys
    sign_in(@owner)
    Factory[:space, user_id: @owner.id, slug: "prop-check", status: "active"]
    _, _, body = inertia_get("/spaces")
    space = parse_json(body)["props"]["spaces"].first
    %w[id slug title status iterations_count runs_count imported_at].each do |key|
      assert space.key?(key), "spaces props must include '#{key}'"
    end
    assert_equal "active", space["status"]
    assert_equal 0,        space["iterations_count"]
    assert_equal 0,        space["runs_count"]
  end

  # ── Show ─────────────────────────────────────────────────────────────────────

  def test_show_returns_404_for_missing_space
    status, _, _ = inertia_get("/spaces/999999")
    assert_equal 404, status
  end

  def test_show_redirects_anon_on_private_space
    space = Factory[:space, user_id: @owner.id, slug: "private-space"]
    status, headers, _ = get("/spaces/#{space.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_show_redirects_other_signed_in_user
    space = Factory[:space, user_id: @other.id, slug: "other-private"]
    sign_in(@owner)
    status, headers, _ = get("/spaces/#{space.id}")
    assert_equal 302, status
  end

  def test_show_returns_200_for_owner
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "owner-space", title: "Owner Space", status: "active"]
    status, _, body = inertia_get("/spaces/#{space.id}")
    assert_equal 200, status
    data = parse_json(body)
    assert_equal "Spaces/Show", data["component"]
  end

  def test_show_space_props_include_required_keys
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "show-space", title: "Show Space", status: "active"]
    _, _, body = inertia_get("/spaces/#{space.id}")
    space_data = parse_json(body)["props"]["space"]
    assert_equal space.id,    space_data["id"]
    assert_equal "show-space", space_data["slug"]
    assert_equal "active",     space_data["status"]
    assert space_data.key?("repos")
  end

  def test_show_returns_iterations_unassigned_runs_other_artifacts
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "full-space"]
    _, _, body = inertia_get("/spaces/#{space.id}")
    props = parse_json(body)["props"]
    assert props.key?("iterations"),      "must include iterations"
    assert props.key?("unassigned_runs"), "must include unassigned_runs"
    assert props.key?("other_artifacts"), "must include other_artifacts"
    assert_kind_of Array, props["iterations"]
    assert_kind_of Array, props["unassigned_runs"]
    assert_kind_of Array, props["other_artifacts"]
  end

  def test_show_includes_iterations_with_artifacts_and_runs
    sign_in(@owner)
    space    = Factory[:space,     user_id: @owner.id, slug: "iter-space"]
    iter     = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    artifact = Factory[:artifact,  space_id: space.id, iteration_id: iter.id,
                       kind: "iteration", path: "arch/I01.md", title: "I01"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iterations = parse_json(body)["props"]["iterations"]
    assert_equal 1,       iterations.length
    assert_equal iter.id, iterations.first["id"]
    assert_equal 1,       iterations.first["ordinal"]

    arts = iterations.first["artifacts"]
    assert_equal 1,           arts.length
    assert_equal artifact.id, arts.first["id"]
    assert_equal "iteration", arts.first["kind"]
  end

  def test_show_other_artifacts_excludes_iteration_linked_artifacts
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "art-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    Factory[:artifact, space_id: space.id, iteration_id: nil,     kind: "brief",       path: "architecture/BRIEF.md", title: "Brief"]
    Factory[:artifact, space_id: space.id, iteration_id: nil,     kind: "architect_index", path: "architecture/ARCHITECT.md", title: "Architect"]
    Factory[:artifact, space_id: space.id, iteration_id: iter.id, kind: "iteration",   path: "architecture/I01.md",   title: "I01"]
    Factory[:artifact, space_id: space.id, iteration_id: iter.id, kind: "lane_prompt", path: "build/I01-lane-a/prompt.md", title: "Prompt"]
    Factory[:artifact, space_id: space.id, iteration_id: iter.id, kind: "lane_report", path: "build/I01-lane-a/report.md", title: "Report"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    props = parse_json(body)["props"]
    other = props["other_artifacts"]
    other_kinds = other.map { |a| a["kind"] }

    # Only space-level (iteration_id nil) artifacts appear in other_artifacts
    assert_includes other_kinds, "brief"
    assert_includes other_kinds, "architect_index"
    assert_equal 2, other.length, "other_artifacts must contain only space-level artifacts"

    # Iteration-linked artifacts (including lane_prompt/lane_report) appear under their iteration
    iter_arts = props["iterations"].first["artifacts"]
    iter_art_kinds = iter_arts.map { |a| a["kind"] }
    assert_includes iter_art_kinds, "iteration"
    assert_includes iter_art_kinds, "lane_prompt"
    assert_includes iter_art_kinds, "lane_report"

    # None of the iteration-linked artifacts appear in other_artifacts
    refute_includes other_kinds, "iteration"
    refute_includes other_kinds, "lane_prompt"
    refute_includes other_kinds, "lane_report"
  end

  def test_show_visibility_honored
    sign_in(@owner)
    own_space   = Factory[:space, user_id: @owner.id, slug: "own"]
    other_space = Factory[:space, user_id: @other.id, slug: "other"]

    own_status, _, _   = inertia_get("/spaces/#{own_space.id}")
    other_status, _, _ = inertia_get("/spaces/#{other_space.id}")

    assert_equal 200, own_status,   "owner can see their own space"
    assert_equal 302, other_status, "owner cannot see another user's space"
  end
end

# frozen_string_literal: true

require_relative "../action_test_helper"

class SpacesArtifactTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "artifact-owner-uid", username: "artifact-owner"]
    @other = Factory[:user, github_uid: "artifact-other-uid", username: "artifact-other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # ── happy path ────────────────────────────────────────────────────────────────

  def test_artifact_renders_spaces_artifact_component
    sign_in(@owner)
    space, artifact = space_with_artifact
    status, _, body = inertia_get("/spaces/#{space.id}/artifacts/#{artifact.id}")
    assert_equal 200, status
    assert_equal "Spaces/Artifact", parse_json(body)["component"]
  end

  def test_artifact_props_include_space_and_artifact_with_raw
    sign_in(@owner)
    space, artifact = space_with_artifact
    _, _, body = inertia_get("/spaces/#{space.id}/artifacts/#{artifact.id}")
    props = parse_json(body)["props"]

    assert props.key?("space"),    "props must include space"
    assert props.key?("artifact"), "props must include artifact"

    space_data = props["space"]
    assert_equal space.id,   space_data["id"]
    assert_equal space.slug, space_data["slug"]
    assert space_data.key?("title")

    art_data = props["artifact"]
    assert_equal artifact.id,   art_data["id"]
    assert_equal artifact.kind, art_data["kind"]
    assert_equal artifact.path, art_data["path"]
    assert art_data.key?("raw"),   "artifact props must include raw"
    refute_nil art_data["raw"],    "raw must be non-nil"
    refute_empty art_data["raw"],  "raw must be non-empty"
    assert_match "# Test Brief", art_data["raw"]
  end

  # ── 404 when artifact does not belong to space ────────────────────────────────

  def test_artifact_returns_404_when_artifact_belongs_to_different_space
    sign_in(@owner)
    space1 = Factory[:space, user_id: @owner.id, slug: "art-space-one"]
    space2 = Factory[:space, user_id: @owner.id, slug: "art-space-two"]
    artifact = Factory[:artifact, space_id: space2.id, kind: "brief",
                       path: "architecture/ARCHITECT.md", title: "Brief",
                       raw: "# Brief\n\nContent."]

    status, _, _ = inertia_get("/spaces/#{space1.id}/artifacts/#{artifact.id}")
    assert_equal 404, status
  end

  def test_artifact_returns_404_for_missing_artifact
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "art-missing-space"]
    status, _, _ = inertia_get("/spaces/#{space.id}/artifacts/999999")
    assert_equal 404, status
  end

  # ── visibility guard ──────────────────────────────────────────────────────────

  def test_artifact_redirects_anon_on_private_space
    space    = Factory[:space, user_id: @owner.id, slug: "art-private-space"]
    artifact = Factory[:artifact, space_id: space.id, kind: "brief",
                       path: "architecture/ARCHITECT.md", title: "Brief",
                       raw: "# Brief\n\nContent."]

    status, headers, _ = get("/spaces/#{space.id}/artifacts/#{artifact.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_artifact_redirects_non_owner_on_private_space
    sign_in(@other)
    space    = Factory[:space, user_id: @owner.id, slug: "art-other-space"]
    artifact = Factory[:artifact, space_id: space.id, kind: "brief",
                       path: "architecture/ARCHITECT.md", title: "Brief",
                       raw: "# Brief\n\nContent."]

    status, _, _ = get("/spaces/#{space.id}/artifacts/#{artifact.id}")
    assert_equal 302, status
  end

  private

  def space_with_artifact
    space    = Factory[:space, user_id: @owner.id, slug: "art-happy-#{SecureRandom.hex(4)}"]
    artifact = Factory[:artifact, space_id: space.id, kind: "brief",
                       path: "architecture/ARCHITECT.md", title: "Brief",
                       raw: "# Test Brief\n\nThe brief content here."]
    [space, artifact]
  end
end

# frozen_string_literal: true

require_relative "../action_test_helper"

class SpacesIndexTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "i07-index-owner-uid", username: "i07-index-owner"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # ── git_utc_offset (AC-3) ──────────────────────────────────────────────────────

  def test_index_space_row_includes_git_utc_offset_key
    sign_in(@owner)
    Factory[:space, user_id: @owner.id, slug: "idx-offset-key-space"]

    _, _, body = inertia_get("/spaces")
    space_row = parse_json(body)["props"]["spaces"].first

    assert space_row.key?("git_utc_offset"), "space row must include git_utc_offset key"
  end

  def test_index_space_row_git_utc_offset_nil_by_default
    sign_in(@owner)
    Factory[:space, user_id: @owner.id, slug: "idx-offset-nil-space"]

    _, _, body = inertia_get("/spaces")
    space_row = parse_json(body)["props"]["spaces"].first

    assert_nil space_row["git_utc_offset"]
  end

  def test_index_space_row_git_utc_offset_integer_when_set
    sign_in(@owner)
    Factory[:space, user_id: @owner.id, slug: "idx-offset-set-space", git_utc_offset: -21600]

    _, _, body = inertia_get("/spaces")
    space_row = parse_json(body)["props"]["spaces"].first

    assert_equal(-21600, space_row["git_utc_offset"])
  end

  # ── imported_at microsecond precision (AC-3) ───────────────────────────────────

  def test_index_space_row_imported_at_nil_when_not_set
    sign_in(@owner)
    Factory[:space, user_id: @owner.id, slug: "idx-imported-nil-space"]

    _, _, body = inertia_get("/spaces")
    space_row = parse_json(body)["props"]["spaces"].first

    assert space_row.key?("imported_at"), "space row must include imported_at key"
    assert_nil space_row["imported_at"]
  end

  def test_index_space_row_imported_at_microsecond_precision_when_set
    sign_in(@owner)
    t = Time.parse("2026-06-28T21:32:12.278000Z").utc
    Factory[:space, user_id: @owner.id, slug: "idx-imported-micro-space", imported_at: t]

    _, _, body = inertia_get("/spaces")
    space_row = parse_json(body)["props"]["spaces"].first

    assert_match(/T\d\d:\d\d:\d\d\.\d{6}/, space_row["imported_at"],
      "imported_at must have 6 fractional digits")
  end
end

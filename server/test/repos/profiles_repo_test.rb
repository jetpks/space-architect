# frozen_string_literal: true

require_relative "../test_helper"

class ProfilesRepoTest < Minitest::Test
  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    Faker::Lorem.unique.clear
    [:profiles, :artifacts, :iterations, :annotations, :conversation_shares, :messages, :conversations, :jobs, :runs, :spaces, :users].each { |t| conn[t].delete }
  end

  def profiles_repo = Space::Server::Repos::ProfilesRepo.new

  def make_user(overrides = {})
    Factory[:user, **overrides]
  end

  def test_crud_round_trip
    user = make_user
    profile = Factory[:profile, user_id: user.id]
    assert_kind_of Integer, profile.id
    assert_equal "claude", profiles_repo.by_pk(profile.id).harness_type

    profiles_repo.delete(profile.id)
    assert_nil profiles_repo.by_pk(profile.id)
  end

  def test_spec_jsonb_round_trips
    user = make_user
    spec = {
      "harness" => { "type" => "claude", "model" => "sonnet", "backend" => { "base_url" => "https://api.example.com" } },
      "environment" => { "env" => { "FOO" => "bar" }, "secrets" => [{ "ref" => "op://x", "name" => "Y" }], "deps" => ["git"] }
    }
    profile = Factory[:profile, user_id: user.id, spec: spec]
    found = profiles_repo.by_pk(profile.id)
    assert_equal spec, found.spec
  end

  def test_list_for_user_orders_by_name
    user = make_user
    Factory[:profile, user_id: user.id, name: "zeta"]
    Factory[:profile, user_id: user.id, name: "alpha"]
    Factory[:profile, user_id: user.id, name: "mid"]

    names = profiles_repo.list_for_user(user.id).map(&:name)
    assert_equal %w[alpha mid zeta], names
  end

  def test_list_for_user_scopes_to_owner
    u1 = make_user
    u2 = make_user
    p1 = Factory[:profile, user_id: u1.id]
    Factory[:profile, user_id: u2.id]

    ids = profiles_repo.list_for_user(u1.id).map(&:id)
    assert_equal [p1.id], ids
  end

  def test_unique_name_per_user_constraint
    user = make_user
    Factory[:profile, user_id: user.id, name: "dup"]
    err = assert_raises(ROM::SQL::UniqueConstraintError) do
      Factory[:profile, user_id: user.id, name: "dup"]
    end
    assert_match(/index_profiles_on_user_id_and_name/, err.message)
  end

  def test_same_name_allowed_across_different_users
    u1 = make_user
    u2 = make_user
    p1 = Factory[:profile, user_id: u1.id, name: "shared-name"]
    p2 = Factory[:profile, user_id: u2.id, name: "shared-name"]
    assert_equal "shared-name", profiles_repo.by_pk(p1.id).name
    assert_equal "shared-name", profiles_repo.by_pk(p2.id).name
  end

  def test_deleting_user_cascades_to_profiles
    user = make_user
    profile = Factory[:profile, user_id: user.id]
    conn[:users].where(id: user.id).delete
    assert_nil profiles_repo.by_pk(profile.id)
  end
end

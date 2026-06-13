# frozen_string_literal: true

require "test_helper"
require "tempfile"

class StateStoreTest < Minitest::Test
  include TestHelpers

  Store = RepoTender::State::Store

  # G7: State store round-trips per-repo + per-org state. Status enum
  # accepts the PRD §3.2 set
  # (clean|dirty|diverged|detached|wrong_branch|missing|error).

  def test_round_trip_preserves_state
    Tempfile.create(["state", ".yaml"]) do |f|
      f.write(<<~YAML)
        repos:
          github.com/ruby/ruby:
            default_branch: trunk
            last_fetch_at: 2026-06-12T20:01:33Z
            last_synced_at: 2026-06-12T20:01:34Z
            status: clean
            last_error:
        orgs:
          github.com/socketry:
            last_listed_at: 2026-06-12T20:00:10Z
            repo_count: 41
      YAML
      f.flush

      state = Store.load(f.path).success
      refute_nil state

      repo = state.repos["github.com/ruby/ruby"]
      refute_nil repo
      assert_equal "trunk", repo.default_branch
      assert_equal "clean", repo.status
      assert_kind_of Time, repo.last_fetch_at

      org = state.orgs["github.com/socketry"]
      refute_nil org
      assert_equal 41, org.repo_count

      out = File.join(Dir.tmpdir, "state-rt-#{rand(1_000_000)}.yaml")
      File.delete(out) if File.exist?(out)
      Store.write(out, state)
      reloaded = Store.load(out).success

      # Same keys, same fields.
      assert_equal state.repos.keys, reloaded.repos.keys
      assert_equal "trunk", reloaded.repos["github.com/ruby/ruby"].default_branch
      assert_equal "clean", reloaded.repos["github.com/ruby/ruby"].status
      assert_equal 41, reloaded.orgs["github.com/socketry"].repo_count

      File.delete(out)
    end
  end

  def test_status_enum_accepts_all_prd_values
    Store::STATUSES.each do |status|
      Store::Repo.new(default_branch: "trunk", status: status, last_error: nil)
      # No raise
    end
  end

  def test_status_enum_rejects_unknown
    state = Store::State.new(
      repos: {"x" => Store::Repo.new(status: "bogus")},
      orgs: {}
    )
    result = Store.validate(state)
    assert result.failure?
    failure = result.failure
    assert_includes failure[:repos]["x"][:status].first, "must be one of"
  end

  def test_missing_file_loads_empty
    path = "/tmp/repo-tender-state-nonexistent-#{rand(1_000_000)}.yaml"
    File.delete(path) if File.exist?(path)
    state = Store.load(path).success
    assert_equal({}, state.repos)
    assert_equal({}, state.orgs)
  end

  # ---- G6 (CF3 part 1): Org carries last_error (round-trips; omitted when nil) ----

  def test_org_last_error_round_trips
    Tempfile.create(["state-org-err", ".yaml"]) do |f|
      f.write(<<~YAML)
        orgs:
          github.com/socketry:
            last_listed_at: 2026-06-12T20:00:10Z
            repo_count: 41
            last_error: "gh not authenticated"
      YAML
      f.flush

      state = Store.load(f.path).success
      org = state.orgs["github.com/socketry"]
      refute_nil org
      assert_equal "gh not authenticated", org.last_error
      assert_equal 41, org.repo_count

      out = File.join(Dir.tmpdir, "state-org-rt-#{rand(1_000_000)}.yaml")
      File.delete(out) if File.exist?(out)
      Store.write(out, state)
      reloaded = Store.load(out).success
      assert_equal "gh not authenticated", reloaded.orgs["github.com/socketry"].last_error
      File.delete(out)
    end
  end

  def test_org_last_error_omitted_from_to_h_compact_when_nil
    org = Store::Org.new(last_listed_at: nil, repo_count: 7, last_error: nil)
    refute_includes org.to_h_compact.keys, "last_error"
  end

  def test_org_last_error_included_in_to_h_compact_when_present
    org = Store::Org.new(last_listed_at: nil, repo_count: 0, last_error: "boom")
    assert_includes org.to_h_compact.keys, "last_error"
    assert_equal "boom", org.to_h_compact["last_error"]
  end

  def test_existing_org_yaml_without_last_error_loads_with_nil
    Tempfile.create(["state-org-no-err", ".yaml"]) do |f|
      f.write(<<~YAML)
        orgs:
          github.com/socketry:
            last_listed_at: 2026-06-12T20:00:10Z
            repo_count: 41
      YAML
      f.flush

      state = Store.load(f.path).success
      org = state.orgs["github.com/socketry"]
      refute_nil org
      assert_nil org.last_error
      assert_equal 41, org.repo_count
    end
  end
end

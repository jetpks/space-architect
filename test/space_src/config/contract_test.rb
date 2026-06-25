# frozen_string_literal: true

require "space_src/test_helper"

class ConfigContractTest < Minitest::Test
  include TestHelpers

  Contract = Space::Src::Config::Contract

  # G2: Failure with field-level messages for each rejection case.

  def test_valid_returns_success
    result = Contract.new.call({base_dir: "/tmp/x", refresh_interval: 3600, concurrency: 4})
    assert result.success?
    assert_kind_of Hash, result.success
  end

  def test_missing_required_field_on_nested_repo
    # The top-level fields all have defaults (PRD §3.1); a "missing
    # required field" assertion targets a nested struct field. A repo
    # entry without :owner must fail.
    result = Contract.new.call({repos: [{name: "ruby"}]})
    assert result.failure?
    assert_includes result.failure.inspect, "owner"
    assert_includes result.failure.inspect, "is missing"
  end

  def test_bad_refresh_interval
    result = Contract.new.call({refresh_interval: "6x"})
    assert result.failure?
    failure = result.failure
    assert_includes failure[:refresh_interval].first, "must be an integer"
  end

  def test_non_integer_concurrency_string
    result = Contract.new.call({concurrency: "8"})
    assert result.failure?
    assert_includes result.failure[:concurrency].first, "must be an integer"
  end

  def test_non_integer_concurrency_float
    result = Contract.new.call({concurrency: 8.5})
    assert result.failure?
    assert_includes result.failure[:concurrency].first, "must be an integer"
  end

  def test_malformed_repo_entry
    result = Contract.new.call({repos: [{owner: 123, name: "ruby"}]})
    assert result.failure?
    # Field-level message on repos[0].owner.
    failure = result.failure
    refute_nil failure[:repos]
    assert_includes failure[:repos][0][:owner].first, "must be a string"
  end

  def test_malformed_org_entry
    result = Contract.new.call({orgs: [{name: 123}]})
    assert result.failure?
    failure = result.failure
    refute_nil failure[:orgs]
    assert_includes failure[:orgs][0][:name].first, "must be a string"
  end

  # GA5: ignored_repos validation
  def test_ignored_repos_valid_array_of_strings_passes
    result = Contract.new.call({orgs: [{name: "bigco", ignored_repos: ["x", "y"]}]})
    assert result.success?, "expected success, got #{result.failure.inspect}"
  end

  def test_ignored_repos_empty_array_passes
    result = Contract.new.call({orgs: [{name: "bigco", ignored_repos: []}]})
    assert result.success?, "expected success, got #{result.failure.inspect}"
  end

  def test_ignored_repos_non_array_fails
    result = Contract.new.call({orgs: [{name: "bigco", ignored_repos: "monorepo"}]})
    assert result.failure?
    failure = result.failure
    refute_nil failure[:orgs], "expected field-level error under :orgs"
    assert failure[:orgs][0][:ignored_repos], "expected error on ignored_repos"
  end

  def test_ignored_repos_array_with_non_string_element_fails
    result = Contract.new.call({orgs: [{name: "bigco", ignored_repos: [42]}]})
    assert result.failure?
    failure = result.failure
    refute_nil failure[:orgs]
    assert failure[:orgs][0][:ignored_repos], "expected error on ignored_repos element"
  end
end

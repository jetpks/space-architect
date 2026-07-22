# frozen_string_literal: true

require_relative "../test_helper"
require "tempfile"

class SessionSyncPlistTest < Space::ArchitectTest
  Plist = Space::Architect::SessionSync::Plist
  LABEL = Space::Architect::SessionSync::LABEL
  TOKEN_ENV = Space::Architect::SessionSync::TOKEN_ENV
  BIN_PATH = "/Users/eric/.gem/ruby/4.0.0/bin/architect"
  LOG_DIR = "/Users/eric/.local/state/space-architect/logs"

  def fixture_xml(host: "https://example.com", env: {TOKEN_ENV => "secret-token"}, refresh_interval: 900)
    Plist.call(
      label: LABEL,
      refresh_interval: refresh_interval,
      log_dir: LOG_DIR,
      bin_path: BIN_PATH,
      host: host,
      env: env
    )
  end

  def test_emitted_plist_is_plutil_lint_clean
    Tempfile.create(["plist", ".plist"]) do |f|
      f.write(fixture_xml)
      f.flush
      out = `plutil -lint #{f.path} 2>&1`
      assert_equal 0, $?.exitstatus, "plutil -lint failed: #{out}"
    end
  end

  def test_emitted_plist_contains_label
    assert_match(/<key>Label<\/key>\s*<string>#{Regexp.escape(LABEL)}<\/string>/o, fixture_xml)
  end

  # AC5: argv runs `sessions sync` with the configured host, and carries no token material.
  def test_emitted_plist_program_arguments_run_sessions_sync_with_host_only
    xml = fixture_xml(host: "https://example.com")
    m = xml.match(/<key>ProgramArguments<\/key>\s*<array>(.*?)<\/array>/m)
    refute_nil m, "ProgramArguments array missing"
    args = m[1].scan(/<string>([^<]*)<\/string>/).flatten
    assert_equal [BIN_PATH, "sessions", "sync", "--host", "https://example.com"], args
  end

  def test_program_arguments_contains_no_token_flag
    refute_match(/--token/, fixture_xml)
  end

  # AC2: EnvironmentVariables carries the resolved token value verbatim (Plist never resolves).
  def test_environment_variables_dict_contains_ingest_token
    xml = fixture_xml(env: {TOKEN_ENV => "resolved-secret"})
    assert_match(
      %r{<key>EnvironmentVariables</key>\s*<dict>\s*<key>#{Regexp.escape(TOKEN_ENV)}</key>\s*<string>resolved-secret</string>\s*</dict>},
      xml
    )
  end

  def test_op_ref_passed_through_env_is_not_resolved
    xml = fixture_xml(env: {TOKEN_ENV => "op://vault/space-architect/session-sync-token"})
    assert_match(%r{<string>op://vault/space-architect/session-sync-token</string>}, xml)
  end

  # AC5: the requested StartInterval is honored.
  def test_emitted_plist_contains_requested_start_interval
    xml = fixture_xml(refresh_interval: 1800)
    assert_match(/<key>StartInterval<\/key>\s*<integer>1800<\/integer>/, xml)
  end

  def test_emitted_plist_has_no_keep_alive
    refute_match(/<key>KeepAlive<\/key>/, fixture_xml)
  end

  def test_rejects_empty_label
    assert_raises(ArgumentError) do
      Plist.call(label: "", refresh_interval: 900, log_dir: LOG_DIR, bin_path: BIN_PATH, host: "h", env: {TOKEN_ENV => "t"})
    end
  end

  def test_rejects_non_positive_refresh_interval
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 0, log_dir: LOG_DIR, bin_path: BIN_PATH, host: "h", env: {TOKEN_ENV => "t"})
    end
  end

  def test_rejects_relative_paths
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 900, log_dir: "relative/dir", bin_path: BIN_PATH, host: "h", env: {TOKEN_ENV => "t"})
    end
  end

  def test_rejects_missing_host_or_token_env
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 900, log_dir: LOG_DIR, bin_path: BIN_PATH, host: "", env: {TOKEN_ENV => "t"})
    end
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 900, log_dir: LOG_DIR, bin_path: BIN_PATH, host: "h", env: {TOKEN_ENV => ""})
    end
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 900, log_dir: LOG_DIR, bin_path: BIN_PATH, host: "h", env: {})
    end
  end
end

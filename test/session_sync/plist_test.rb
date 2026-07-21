# frozen_string_literal: true

require_relative "../test_helper"
require "tempfile"

class SessionSyncPlistTest < Space::ArchitectTest
  Plist = Space::Architect::SessionSync::Plist
  LABEL = Space::Architect::SessionSync::LABEL
  BIN_PATH = "/Users/eric/.gem/ruby/4.0.0/bin/architect"
  LOG_DIR = "/Users/eric/.local/state/space-architect/logs"

  def fixture_xml(host: "https://example.com", token: "secret-token", refresh_interval: 900)
    Plist.call(
      label: LABEL,
      refresh_interval: refresh_interval,
      log_dir: LOG_DIR,
      bin_path: BIN_PATH,
      host: host,
      token: token
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

  # AC5: argv runs `sessions sync` with the configured host/token.
  def test_emitted_plist_program_arguments_run_sessions_sync_with_host_and_token
    xml = fixture_xml(host: "https://example.com", token: "secret-token")
    m = xml.match(/<key>ProgramArguments<\/key>\s*<array>(.*?)<\/array>/m)
    refute_nil m, "ProgramArguments array missing"
    args = m[1].scan(/<string>([^<]*)<\/string>/).flatten
    assert_equal [BIN_PATH, "sessions", "sync", "--host", "https://example.com", "--token", "secret-token"], args
  end

  # AC5: an op:// token appears as the REF, never resolved.
  def test_op_token_appears_as_ref_not_resolved
    xml = fixture_xml(token: "op://vault/space-architect/session-sync-token")
    assert_match(/<string>op:\/\/vault\/space-architect\/session-sync-token<\/string>/, xml)
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
      Plist.call(label: "", refresh_interval: 900, log_dir: LOG_DIR, bin_path: BIN_PATH, host: "h", token: "t")
    end
  end

  def test_rejects_non_positive_refresh_interval
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 0, log_dir: LOG_DIR, bin_path: BIN_PATH, host: "h", token: "t")
    end
  end

  def test_rejects_relative_paths
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 900, log_dir: "relative/dir", bin_path: BIN_PATH, host: "h", token: "t")
    end
  end

  def test_rejects_missing_host_or_token
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 900, log_dir: LOG_DIR, bin_path: BIN_PATH, host: "", token: "t")
    end
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 900, log_dir: LOG_DIR, bin_path: BIN_PATH, host: "h", token: "")
    end
  end
end

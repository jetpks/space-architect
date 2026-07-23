# frozen_string_literal: true

require_relative "../test_helper"
require "tempfile"

class SessionSyncPlistTest < Space::ArchitectTest
  Plist = Space::Architect::SessionSync::Plist
  LABEL = Space::Architect::SessionSync::LABEL
  TOKEN_ENV = Space::Architect::SessionSync::TOKEN_ENV
  BIN_PATH = "/Users/eric/.gem/ruby/4.0.0/bin/architect"
  RUBY_BIN = "/opt/homebrew/opt/ruby/bin/ruby"
  LOG_DIR = "/Users/eric/.local/state/space-architect/logs"

  def fixture_xml(host: "https://example.com", env: {TOKEN_ENV => "secret-token"}, refresh_interval: 900, ruby_bin: RUBY_BIN)
    Plist.call(
      label: LABEL,
      refresh_interval: refresh_interval,
      log_dir: LOG_DIR,
      bin_path: BIN_PATH,
      ruby_bin: ruby_bin,
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
    assert_equal [RUBY_BIN, BIN_PATH, "sessions", "sync", "--host", "https://example.com"], args
  end

  # AC1: no env-shebang resolution — ruby_bin is named explicitly and absolute,
  # never `/usr/bin/env` or a bare (non-absolute) executable name.
  def test_emitted_plist_has_no_env_shebang_or_bare_command
    xml = fixture_xml
    refute_match(%r{/usr/bin/env}, xml)
    m = xml.match(/<key>ProgramArguments<\/key>\s*<array>(.*?)<\/array>/m)
    args = m[1].scan(/<string>([^<]*)<\/string>/).flatten
    assert File.absolute_path?(args[0]), "ProgramArguments[0] (#{args[0].inspect}) must be absolute"
    assert File.absolute_path?(args[1]), "ProgramArguments[1] (#{args[1].inspect}) must be absolute"
  end

  def test_program_arguments_contains_no_token_flag
    refute_match(/--token/, fixture_xml)
  end

  # AC2: EnvironmentVariables carries the resolved token value verbatim (Plist never resolves).
  def test_environment_variables_dict_contains_ingest_token
    xml = fixture_xml(env: {TOKEN_ENV => "resolved-secret"})
    assert_match(
      %r{<key>EnvironmentVariables</key>\s*<dict>.*<key>#{Regexp.escape(TOKEN_ENV)}</key>\s*<string>resolved-secret</string>.*</dict>}m,
      xml
    )
  end

  def test_op_ref_passed_through_env_is_not_resolved
    xml = fixture_xml(env: {TOKEN_ENV => "op://vault/space-architect/session-sync-token"})
    assert_match(%r{<string>op://vault/space-architect/session-sync-token</string>}, xml)
  end

  # AC2: EnvironmentVariables carries a default PATH with homebrew + system dirs
  # so subprocesses the sync spawns resolve under launchd's bare PATH.
  def test_environment_variables_dict_contains_default_path
    xml = fixture_xml
    assert_match(
      %r{<key>EnvironmentVariables</key>\s*<dict>.*<key>PATH</key>\s*<string>#{Regexp.escape(Space::Architect::SessionSync::Plist::DEFAULT_PATH)}</string>.*</dict>}m,
      xml
    )
    assert_includes Space::Architect::SessionSync::Plist::DEFAULT_PATH, "/opt/homebrew/bin"
    assert_includes Space::Architect::SessionSync::Plist::DEFAULT_PATH, "/usr/bin"
    assert_includes Space::Architect::SessionSync::Plist::DEFAULT_PATH, "/bin"
  end

  # AC2: an explicit caller-supplied PATH wins over the default.
  def test_caller_supplied_path_wins_over_default
    xml = fixture_xml(env: {TOKEN_ENV => "secret-token", "PATH" => "/custom/bin"})
    assert_match(
      %r{<key>EnvironmentVariables</key>\s*<dict>.*<key>PATH</key>\s*<string>/custom/bin</string>.*</dict>}m,
      xml
    )
    refute_match(%r{<string>#{Regexp.escape(Space::Architect::SessionSync::Plist::DEFAULT_PATH)}</string>}, xml)
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
      Plist.call(label: "", refresh_interval: 900, log_dir: LOG_DIR, bin_path: BIN_PATH, ruby_bin: RUBY_BIN, host: "h", env: {TOKEN_ENV => "t"})
    end
  end

  def test_rejects_non_positive_refresh_interval
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 0, log_dir: LOG_DIR, bin_path: BIN_PATH, ruby_bin: RUBY_BIN, host: "h", env: {TOKEN_ENV => "t"})
    end
  end

  def test_rejects_relative_paths
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 900, log_dir: "relative/dir", bin_path: BIN_PATH, ruby_bin: RUBY_BIN, host: "h", env: {TOKEN_ENV => "t"})
    end
  end

  def test_rejects_relative_ruby_bin
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 900, log_dir: LOG_DIR, bin_path: BIN_PATH, ruby_bin: "ruby", host: "h", env: {TOKEN_ENV => "t"})
    end
  end

  def test_rejects_missing_host_or_token_env
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 900, log_dir: LOG_DIR, bin_path: BIN_PATH, ruby_bin: RUBY_BIN, host: "", env: {TOKEN_ENV => "t"})
    end
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 900, log_dir: LOG_DIR, bin_path: BIN_PATH, ruby_bin: RUBY_BIN, host: "h", env: {TOKEN_ENV => ""})
    end
    assert_raises(ArgumentError) do
      Plist.call(label: LABEL, refresh_interval: 900, log_dir: LOG_DIR, bin_path: BIN_PATH, ruby_bin: RUBY_BIN, host: "h", env: {})
    end
  end
end

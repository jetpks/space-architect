# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "open3"
require "json"
require_relative "test_helper"
require "space/server/opencode_store"

class OpencodeStoreTest < Minitest::Test
  TARGET_DIR  = "/test/space/target"
  OTHER_DIR   = "/test/space/other"
  QUOTE_DIR   = "/test/space/it's/here"
  SESSION_A   = "ses_store_test_A"
  SESSION_B   = "ses_store_test_B"
  SESSION_C   = "ses_store_test_C"

  def setup
    @tmpdir  = Dir.mktmpdir("opencode_store_test")
    @db_path = File.join(@tmpdir, "opencode.db")
    build_fixture_db
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def store
    @store ||= Space::Server::OpencodeStore.new(@db_path)
  end

  # ── available? ────────────────────────────────────────────────────────────────

  def test_available_true_for_existing_db
    assert store.available?
  end

  def test_available_false_for_missing_path
    s = Space::Server::OpencodeStore.new("/nonexistent/path/opencode.db")
    refute s.available?
  end

  def test_missing_db_sessions_for_returns_empty_no_raise
    s = Space::Server::OpencodeStore.new("/nonexistent/path/opencode.db")
    assert_equal [], s.sessions_for("/any/dir")
  end

  def test_missing_db_messages_for_returns_empty_no_raise
    s = Space::Server::OpencodeStore.new("/nonexistent/path/opencode.db")
    assert_equal [], s.messages_for("ses_any")
  end

  # ── sessions_for ──────────────────────────────────────────────────────────────

  def test_sessions_for_returns_only_matching_directory
    results = store.sessions_for(TARGET_DIR)
    assert_equal 1, results.length
    assert_equal SESSION_A, results.first["id"]
  end

  def test_sessions_for_excludes_other_directory
    results = store.sessions_for(TARGET_DIR)
    ids = results.map { |r| r["id"] }
    refute_includes ids, SESSION_B
  end

  def test_sessions_for_returns_empty_for_unknown_directory
    assert_equal [], store.sessions_for("/no/such/dir")
  end

  def test_sessions_for_ordered_by_time_created_then_id
    # Insert a second session in TARGET_DIR with later time_created
    run_sql("INSERT INTO session VALUES ('ses_store_test_A2', '#{TARGET_DIR}', 'build', '{}', 'S2', NULL, 1750000002000, 1750000002000);")
    results = store.sessions_for(TARGET_DIR)
    assert_equal 2, results.length
    assert_equal SESSION_A,         results[0]["id"]
    assert_equal "ses_store_test_A2", results[1]["id"]
  end

  def test_sessions_for_parses_model_json_into_hash
    results = store.sessions_for(TARGET_DIR)
    model = results.first["model"]
    assert_kind_of Hash, model
    assert_equal "anthropic",       model["providerID"]
    assert_equal "opencode-model-1", model["id"]
  end

  def test_sessions_for_model_nil_for_garbage_json
    results = store.sessions_for(OTHER_DIR)
    assert_nil results.first["model"]
  end

  # ── injection safety ─────────────────────────────────────────────────────────

  def test_sessions_for_single_quote_in_directory_does_not_raise
    result = store.sessions_for(QUOTE_DIR)
    assert_equal 1, result.length
    assert_equal SESSION_C, result.first["id"]
  end

  def test_sessions_for_sql_injection_attempt_returns_empty
    assert_equal [], store.sessions_for("' OR '1'='1")
  end

  # ── messages_for ─────────────────────────────────────────────────────────────

  def test_messages_for_returns_messages_for_session
    results = store.messages_for(SESSION_A)
    assert_equal 2, results.length
  end

  def test_messages_for_messages_ordered_by_time_created
    results = store.messages_for(SESSION_A)
    assert_equal "msg_store_u1", results[0]["id"]
    assert_equal "msg_store_a1", results[1]["id"]
  end

  def test_messages_for_data_parsed_into_hash
    results = store.messages_for(SESSION_A)
    results.each do |m|
      assert_kind_of Hash, m["data"]
    end
  end

  def test_messages_for_parts_ordered_within_message
    results = store.messages_for(SESSION_A)
    asst = results.find { |m| m["data"]["role"] == "assistant" }
    refute_nil asst
    parts = asst["parts"]
    assert parts.length >= 2
    assert_equal "step-start", parts[0]["type"]
    assert_equal "text",       parts[1]["type"]
  end

  def test_messages_for_parts_data_parsed_into_hashes
    results = store.messages_for(SESSION_A)
    results.each do |m|
      m["parts"].each do |part|
        assert_kind_of Hash, part
      end
    end
  end

  def test_messages_for_returns_empty_for_unknown_session
    assert_equal [], store.messages_for("ses_nonexistent")
  end

  def test_messages_for_excludes_other_sessions_messages
    results = store.messages_for(SESSION_A)
    assert results.none? { |m| m["data"]["session_id"] == SESSION_B }
  end

  private

  def build_fixture_db
    schema_sql = <<~SQL
      CREATE TABLE session (id TEXT, directory TEXT, agent TEXT, model TEXT, title TEXT, parent_id TEXT, time_created INTEGER, time_updated INTEGER);
      CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
      CREATE TABLE part (id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
    SQL

    model_a = '{"id":"opencode-model-1","providerID":"anthropic","variant":"default"}'

    data_sql = <<~SQL
      INSERT INTO session VALUES ('#{SESSION_A}', '#{TARGET_DIR}', 'build', '#{model_a}', 'Session A', NULL, 1750000000000, 1750000001000);
      INSERT INTO session VALUES ('#{SESSION_B}', '#{OTHER_DIR}',  'build', 'not json',   'Session B', NULL, 1750000001000, 1750000002000);
      INSERT INTO session VALUES ('#{SESSION_C}', '#{QUOTE_DIR.gsub("'", "''")}', 'build', '{}', 'Session C', NULL, 1750000003000, 1750000004000);

      INSERT INTO message VALUES ('msg_store_u1', '#{SESSION_A}', 1750000000100, '{"role":"user","time":{"created":1750000000100}}');
      INSERT INTO message VALUES ('msg_store_a1', '#{SESSION_A}', 1750000000200, '{"role":"assistant","modelID":"opencode-model-1","providerID":"anthropic","tokens":{"total":50}}');
      INSERT INTO message VALUES ('msg_store_b1', '#{SESSION_B}', 1750000001100, '{"role":"user"}');

      INSERT INTO part VALUES ('prt_su1p1', 'msg_store_u1', '#{SESSION_A}', 1750000000110, '{"type":"text","text":"Hello"}');
      INSERT INTO part VALUES ('prt_sa1p1', 'msg_store_a1', '#{SESSION_A}', 1750000000210, '{"type":"step-start"}');
      INSERT INTO part VALUES ('prt_sa1p2', 'msg_store_a1', '#{SESSION_A}', 1750000000220, '{"type":"text","text":"I respond"}');
      INSERT INTO part VALUES ('prt_sa1p3', 'msg_store_a1', '#{SESSION_A}', 1750000000230, '{"type":"step-finish","reason":"stop","tokens":{}}');
    SQL

    run_sql(schema_sql + data_sql)
  end

  def run_sql(sql)
    _out, err, status = Open3.capture3("sqlite3", @db_path, stdin_data: sql)
    raise "sqlite3 failed: #{err}" unless status.success?
  end
end

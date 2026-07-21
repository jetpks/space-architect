# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"

class SessionSyncRunnerTest < Space::ArchitectTest
  Runner = Space::Architect::SessionSync::Runner
  Cursor = Space::Architect::SessionSync::Cursor

  OLD_TIME = Time.at(1_753_000_000)

  # Injected client double — records every upload() call and returns a
  # canned response (defaulting to a fresh 201/"created").
  class FakeClient
    attr_reader :calls

    def initialize(responses: {})
      @calls = []
      @responses = responses
    end

    def upload(path:, session_id:)
      @calls << {path: path, session_id: session_id}
      @responses[path] || {status: 201, conversation_id: 1, action: "created"}
    end
  end

  def write_file(dir, *segments, content: "{}\n", mtime: OLD_TIME)
    path = File.join(dir, *segments)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    File.utime(mtime, mtime, path)
    path
  end

  def with_roots
    Dir.mktmpdir("session-sync-runner-test") do |root|
      pi_root = File.join(root, "pi")
      claude_root = File.join(root, "claude")
      state_path = File.join(root, "state.yaml")
      yield pi_root, claude_root, state_path
    end
  end

  # (a) a brand-new file (no cursor entry, old mtime) is uploaded and recorded.
  def test_new_file_is_uploaded_and_recorded
    with_roots do |pi_root, claude_root, state_path|
      path = write_file(pi_root, "proj", "20260101T000000_sess-one.jsonl", content: "hello\n")

      client = FakeClient.new
      results = Runner.new(client: client, state_path: state_path, pi_root: pi_root, claude_root: claude_root,
        now: -> { Time.now }).call

      assert_equal 1, results.size
      assert_equal :uploaded,  results.first[:action]
      assert_equal "sess-one", results.first[:session_id]
      assert_equal [{path: path, session_id: "sess-one"}], client.calls

      cursor = Cursor.load(state_path)
      refute_nil cursor[path]
      assert_equal File.size(path), cursor[path].size
    end
  end

  # (b) a grown file (recorded size smaller than current size) is re-uploaded.
  def test_grown_file_is_reuploaded
    with_roots do |pi_root, claude_root, state_path|
      path = write_file(claude_root, "proj", "sess-two.jsonl", content: "short\n")
      Cursor.write(state_path, {path => Cursor::Entry.new(size: 1, mtime: OLD_TIME.to_i)})

      client = FakeClient.new(responses: {path => {status: 200, conversation_id: 9, action: "updated"}})
      results = Runner.new(client: client, state_path: state_path, pi_root: pi_root, claude_root: claude_root,
        now: -> { Time.now }).call

      assert_equal 1, results.size
      assert_equal :updated, results.first[:action]
      assert_equal 1, client.calls.size

      cursor = Cursor.load(state_path)
      assert_equal File.size(path), cursor[path].size
    end
  end

  # (c) an unchanged file (recorded size == current size) is skipped, no upload call.
  def test_unchanged_file_is_skipped
    with_roots do |pi_root, claude_root, state_path|
      path = write_file(pi_root, "proj", "20260101T000000_sess-three.jsonl", content: "same\n")
      Cursor.write(state_path, {path => Cursor::Entry.new(size: File.size(path), mtime: OLD_TIME.to_i)})

      client = FakeClient.new
      results = Runner.new(client: client, state_path: state_path, pi_root: pi_root, claude_root: claude_root,
        now: -> { Time.now }).call

      assert_equal 1, results.size
      assert_equal :skipped, results.first[:action]
      assert_empty client.calls
    end
  end

  # (d) a file whose mtime is within the last 60s is skipped THIS RUN regardless
  # of cursor state (mid-write guard) — even a brand-new file.
  def test_recent_mtime_file_is_skipped_this_run
    with_roots do |pi_root, claude_root, state_path|
      write_file(pi_root, "proj", "20260101T000000_sess-four.jsonl", mtime: Time.now)

      client = FakeClient.new
      results = Runner.new(client: client, state_path: state_path, pi_root: pi_root, claude_root: claude_root,
        now: -> { Time.now }).call

      assert_equal 1, results.size
      assert_equal :skipped, results.first[:action]
      assert_empty client.calls
      assert_empty Cursor.load(state_path)
    end
  end

  # (e) dry_run reports what would upload without calling the client or writing the cursor.
  def test_dry_run_does_not_upload_or_record
    with_roots do |pi_root, claude_root, state_path|
      write_file(pi_root, "proj", "20260101T000000_sess-five.jsonl")

      client = FakeClient.new
      results = Runner.new(client: client, state_path: state_path, pi_root: pi_root, claude_root: claude_root,
        now: -> { Time.now }, dry_run: true).call

      assert_equal 1, results.size
      assert_equal :would_upload, results.first[:action]
      assert_empty client.calls
      refute File.exist?(state_path)
    end
  end

  # (f) a failed upload (non-2xx) is reported without being recorded in the cursor.
  def test_failed_upload_is_reported_and_not_recorded
    with_roots do |pi_root, claude_root, state_path|
      path = write_file(pi_root, "proj", "20260101T000000_sess-six.jsonl")

      client = FakeClient.new(responses: {path => {status: 422, errors: ["session_id can't be blank"]}})
      results = Runner.new(client: client, state_path: state_path, pi_root: pi_root, claude_root: claude_root,
        now: -> { Time.now }).call

      assert_equal :failed, results.first[:action]
      assert_equal 422, results.first[:status]
      assert_empty Cursor.load(state_path)
    end
  end

  # (g) both pi and claude roots are scanned in one run, each with its own
  # session-id derivation rule.
  def test_scans_both_pi_and_claude_roots
    with_roots do |pi_root, claude_root, state_path|
      write_file(pi_root, "proj", "20260101T000000_pi-sess.jsonl")
      write_file(claude_root, "proj", "claude-sess.jsonl")

      client = FakeClient.new
      results = Runner.new(client: client, state_path: state_path, pi_root: pi_root, claude_root: claude_root,
        now: -> { Time.now }).call

      session_ids = results.map { |r| r[:session_id] }.sort
      assert_equal %w[claude-sess pi-sess], session_ids
    end
  end
end

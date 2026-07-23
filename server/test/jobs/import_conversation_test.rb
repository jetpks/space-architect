# frozen_string_literal: true

require_relative "../test_helper"
require "async"
require "async/semaphore"

class ImportConversationJobTest < Minitest::Test
  def conn = @conn ||= Space::Server::App["db.gateway"].connection

  def conversations_repo = Space::Server::Repos::ConversationsRepo.new
  def messages_repo      = Space::Server::Repos::MessagesRepo.new

  def fixture_path(name)
    File.join(__dir__, "..", "fixtures", "files", name)
  end

  def setup
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :users].each { |t| conn[t].delete }
  end

  def make_conversation(fixture_name)
    data = Space::Server::SourceFileUploader.store(File.open(fixture_path(fixture_name)))
    Factory[:conversation, source_file_data: data]
  end

  # ── claude_code ───────────────────────────────────────────────────────────────

  def test_claude_code_import_completes
    conv = make_conversation("transcript.jsonl")
    Space::Server::Jobs::ImportConversation.new.call(conv.id)

    conv     = conversations_repo.by_pk(conv.id)
    messages = messages_repo.for_conversation(conv.id)

    assert_equal :completed,   conv.status
    assert_equal "claude_code", conv.source
    assert_equal 3,            messages.size
    assert_equal [0, 1, 2],    messages.map(&:position)
    assert_equal %w[user assistant user], messages.map(&:role)
    assert_equal Space::Server::Transcript::Turn.group(messages).size, conv.turns_count
  end

  # ── codex ─────────────────────────────────────────────────────────────────────

  def test_codex_import_completes
    conv = make_conversation("codex_rollout.jsonl")
    Space::Server::Jobs::ImportConversation.new.call(conv.id)

    conv     = conversations_repo.by_pk(conv.id)
    messages = messages_repo.for_conversation(conv.id)

    assert_equal :completed, conv.status
    assert_equal "codex",    conv.source
    assert_equal 11,         messages.size
    assert_equal (0..10).to_a, messages.map(&:position)
    assert_equal "user",     messages.first.role
  end

  # ── pi tree ───────────────────────────────────────────────────────────────────

  def test_pi_tree_import_completes
    conv = make_conversation("pi_session.jsonl")
    Space::Server::Jobs::ImportConversation.new.call(conv.id)

    conv     = conversations_repo.by_pk(conv.id)
    messages = messages_repo.for_conversation(conv.id)

    assert_equal :completed, conv.status
    assert_equal "pi",       conv.source
    assert_equal 9,          messages.size
    assert_equal [0, 1, 2, 3, 4, 5, 6, 7, 8], messages.map(&:position)
    assert_equal "user",     messages.first.role
  end

  # ── pi streaming ──────────────────────────────────────────────────────────────

  def test_pi_streaming_import_completes
    conv = make_conversation("pi_streaming_session.jsonl")
    Space::Server::Jobs::ImportConversation.new.call(conv.id)

    conv     = conversations_repo.by_pk(conv.id)
    messages = messages_repo.for_conversation(conv.id)

    assert_equal :completed, conv.status
    assert_equal "pi",       conv.source
    assert_equal 5,          messages.size
    assert_equal %w[user assistant assistant user assistant], messages.map(&:role)
  end

  # ── failing fixture: Pi-recognized file with 0 messages ──────────────────────
  # Pi raises PiImportError for 0 messages. The job body swallows it so async-job's
  # retry-forever loop (dequeue rescue → processing_list.retry) never fires.

  def test_failed_import_sets_status_and_does_not_raise
    # A pi-recognized header with no message entries → PiImportError → status:failed
    bad_content = %({"type":"session","version":1,"id":"bad-sess-1"}\n)
    bad_data    = Space::Server::SourceFileUploader.store(StringIO.new(bad_content))
    conv        = Factory[:conversation, source_file_data: bad_data]

    # Must NOT raise — failure is swallowed by the rescue guard
    Space::Server::Jobs::ImportConversation.new.call(conv.id)

    conv = conversations_repo.by_pk(conv.id)
    assert_equal :failed, conv.status
    assert_equal 0, conv.turns_count, "a failed import must not recompute turns_count"
  end

  # ── transient DB errors propagate for async-job's retry (AC1) ────────────────
  # A DB-infrastructure error means the importer never got a chance to persist
  # status:failed, so swallowing it would strand the row at status:pending forever.

  def test_pool_timeout_propagates_out_of_call
    conv = make_conversation("transcript.jsonl")
    raising_repo = Object.new
    def raising_repo.by_pk(*) = raise(Sequel::PoolTimeout, "timeout: 5")

    job = Space::Server::Jobs::ImportConversation.new(conversations_repo: raising_repo)
    assert_raises(Sequel::PoolTimeout) { job.call(conv.id) }
  end

  def test_database_connection_error_propagates_out_of_call
    conv = make_conversation("transcript.jsonl")
    raising_repo = Object.new
    def raising_repo.by_pk(*) = raise(Sequel::DatabaseConnectionError, "connection refused")

    job = Space::Server::Jobs::ImportConversation.new(conversations_repo: raising_repo)
    assert_raises(Sequel::DatabaseConnectionError) { job.call(conv.id) }
  end

  # ── nil source_file guard ─────────────────────────────────────────────────────

  def test_missing_source_file_returns_without_raise
    conv = Factory[:conversation]  # no source_file_data
    Space::Server::Jobs::ImportConversation.new.call(conv.id)
    # Must not raise; status stays pending (no write occurred)
    conv = conversations_repo.by_pk(conv.id)
    assert_equal :pending, conv.status
  end

  # ── missing conversation guard ────────────────────────────────────────────────

  def test_nonexistent_conversation_returns_without_raise
    # Must not raise even for a completely unknown id
    Space::Server::Jobs::ImportConversation.new.call(999_999_999)
  end
end

# ── Delegate concurrency bound (AC2) ──────────────────────────────────────────
# `importer:` is a constructor-injection seam (Delegate defaults to the real
# ImportConversation); swapping it here tests the semaphore bound in isolation,
# without driving real DB imports through it.
class ImportConversationDelegateTest < Minitest::Test
  class ConcurrencyTrackingImporter
    attr_reader :max_concurrent

    def initialize
      @concurrent     = 0
      @max_concurrent = 0
    end

    def new = self

    def call(_conversation_id)
      @concurrent += 1
      @max_concurrent = @concurrent if @concurrent > @max_concurrent
      Async::Task.current.sleep(0.05)
    ensure
      @concurrent -= 1
    end
  end

  def test_concurrent_calls_never_exceed_the_configured_limit
    limit    = Space::Server::Jobs::ImportConversation::MAX_CONCURRENT_IMPORTS
    importer = ConcurrencyTrackingImporter.new
    delegate = Space::Server::Jobs::ImportConversation::Delegate.new(
      semaphore: Async::Semaphore.new(limit), importer: importer
    )

    Sync do |task|
      (limit * 3).times.map { |i| task.async { delegate.call({ "conversation_id" => i }) } }.each(&:wait)
    end

    assert_operator importer.max_concurrent, :<=, limit
    assert_equal limit, importer.max_concurrent, "semaphore should saturate at the limit under contention"
  end
end

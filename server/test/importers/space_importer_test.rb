# frozen_string_literal: true

require_relative "../test_helper"
require "space/server/space_importer"

class SpaceImporterTest < Minitest::Test
  FIXTURE_DIR = File.expand_path("../fixtures/files/space_fixture", __dir__)

  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:artifacts, :iterations, :annotations, :conversation_shares, :messages,
     :conversations, :runs, :spaces, :users].each { |t| conn[t].delete }

    @user = Factory[:user]

    @importer = Space::Server::SpaceImporter.new(
      spaces_repo:        Space::Server::App["repos.spaces_repo"],
      iterations_repo:    Space::Server::App["repos.iterations_repo"],
      artifacts_repo:     Space::Server::App["repos.artifacts_repo"],
      runs_repo:          Space::Server::App["repos.runs_repo"],
      conversations_repo: Space::Server::App["repos.conversations_repo"],
      messages_repo:      Space::Server::App["repos.messages_repo"]
    )
  end

  def import!
    @importer.import!(FIXTURE_DIR, user: @user)
  end

  # ── Space ────────────────────────────────────────────────────────────────────

  def test_creates_exactly_one_space
    import!
    assert_equal 1, conn[:spaces].count
  end

  def test_space_has_correct_slug_and_title
    space = import!
    assert_equal "test-space-fixture", space.slug
    assert_equal "Test Space Fixture",  space.title
  end

  def test_space_has_correct_status
    space = import!
    assert_equal "active", space.status
  end

  def test_space_repos_extracted_from_full_name
    space = import!
    repos = conn[:spaces].first[:repos]
    # repos is stored as jsonb; Sequel returns it as an array
    assert_includes Array(repos), "github.com/testorg/test-repo"
  end

  # ── Iterations ───────────────────────────────────────────────────────────────

  def test_creates_iterations_from_architect_block
    import!
    assert_equal 2, conn[:iterations].count
  end

  def test_iteration_ordinals_and_names
    import!
    iters = conn[:iterations].order(:ordinal).all
    assert_equal 1,                 iters[0][:ordinal]
    assert_equal "first-iteration", iters[0][:name]
    assert_equal "abc123def456",    iters[0][:freeze_sha]
    assert_equal "continue",        iters[0][:verdict]

    assert_equal 2,                  iters[1][:ordinal]
    assert_equal "second-iteration", iters[1][:name]
  end

  # ── Artifacts ────────────────────────────────────────────────────────────────

  def test_imports_brief_artifact
    import!
    brief = conn[:artifacts].where(kind: "brief").first
    refute_nil brief
    assert_equal "architecture/BRIEF.md", brief[:path]
    assert_match "BRIEF",                 brief[:title]
  end

  def test_imports_architect_index_artifact
    import!
    idx = conn[:artifacts].where(kind: "architect_index").first
    refute_nil idx
    assert_equal "architecture/ARCHITECT.md", idx[:path]
  end

  def test_imports_iteration_artifacts
    import!
    iters = conn[:artifacts].where(kind: "iteration").all
    assert iters.length >= 1, "at least one iteration artifact expected"
    paths = iters.map { |a| a[:path] }
    assert_includes paths, "architecture/I01-first-iteration.md"
  end

  def test_iteration_artifact_linked_to_correct_iteration
    import!
    iter_row  = conn[:iterations].where(ordinal: 1).first
    artifact  = conn[:artifacts].where(path: "architecture/I01-first-iteration.md").first
    assert_equal iter_row[:id], artifact[:iteration_id]
  end

  # ── Builder Runs ─────────────────────────────────────────────────────────────

  def test_imports_one_builder_run
    import!
    runs = conn[:runs].where(role: "builder").all
    assert_equal 1, runs.length
  end

  def test_builder_run_attributes
    import!
    run = conn[:runs].where(role: "builder").first
    assert_equal "builder", run[:role]
    assert_equal "lane-a",  run[:lane]
    assert_equal 2,         run[:status]  # complete
    refute_nil run[:iteration_id]
    refute_nil run[:space_id]
  end

  def test_builder_run_linked_to_correct_iteration
    import!
    iter_row = conn[:iterations].where(ordinal: 1).first
    run      = conn[:runs].where(role: "builder").first
    assert_equal iter_row[:id], run[:iteration_id]
  end

  def test_builder_run_has_conversation
    import!
    run = conn[:runs].where(role: "builder").first
    refute_nil run[:conversation_id]
  end

  def test_builder_run_conversation_has_messages
    import!
    run       = conn[:runs].where(role: "builder").first
    msg_count = conn[:messages].where(conversation_id: run[:conversation_id]).count
    assert msg_count >= 1, "at least one message expected from the run fixture"
  end

  # ── Idempotency ──────────────────────────────────────────────────────────────

  def test_second_import_yields_identical_row_counts
    import!
    counts_1 = snapshot_counts
    import!
    counts_2 = snapshot_counts
    assert_equal counts_1, counts_2,
      "second import must not add rows: #{counts_1.inspect} vs #{counts_2.inspect}"
  end

  def test_idempotency_message_count_stable
    import!
    run_id     = conn[:runs].where(role: "builder").first[:id]
    conv_id    = conn[:runs].where(id: run_id).first[:conversation_id]
    msg_count  = conn[:messages].where(conversation_id: conv_id).count

    import!
    new_conv_id   = conn[:runs].where(id: run_id).first[:conversation_id]
    new_msg_count = conn[:messages].where(conversation_id: new_conv_id).count

    assert_equal msg_count, new_msg_count,
      "message count must be identical after reimport"
  end

  private

  def snapshot_counts
    %i[spaces iterations artifacts runs conversations messages].each_with_object({}) do |t, h|
      h[t] = conn[t].count
    end
  end
end

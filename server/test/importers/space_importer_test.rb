# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../test_helper"
require "space/server/space_importer"

class SpaceImporterTest < Minitest::Test
  FIXTURE_DIR       = File.expand_path("../fixtures/files/space_fixture", __dir__)
  SESSION_FIXTURE   = File.expand_path("../fixtures/files/claude_session_fixture.jsonl", __dir__)
  FIXTURE_SESSION_UUID = "aabbccdd-1111-2222-3333-444455556666"

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

  def import!(claude_projects_root: nil)
    if claude_projects_root
      @importer.import!(FIXTURE_DIR, user: @user, claude_projects_root: claude_projects_root)
    else
      @importer.import!(FIXTURE_DIR, user: @user)
    end
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

  # ── Mangle ───────────────────────────────────────────────────────────────────

  def test_mangle_converts_slashes_to_dashes
    assert_equal "-Users-eric-architect-spaces-20260627-space-server-objects",
                 @importer.mangle("/Users/eric/architect/spaces/20260627-space-server-objects")
  end

  # ── Architect Runs ────────────────────────────────────────────────────────────

  def with_staged_session_root
    Dir.mktmpdir("space_importer_test") do |root|
      project_dir = File.join(root, @importer.mangle(FIXTURE_DIR))
      FileUtils.mkdir_p(project_dir)
      FileUtils.cp(SESSION_FIXTURE, File.join(project_dir, "#{FIXTURE_SESSION_UUID}.jsonl"))
      yield root
    end
  end

  def test_architect_run_created_with_correct_attributes
    with_staged_session_root do |root|
      import!(claude_projects_root: root)
      run = conn[:runs].where(role: "architect").first
      refute_nil run
      assert_equal "architect",           run[:role]
      assert_equal 2,                     run[:status]
      assert_equal "claude_session",      run[:producer]
      assert_equal FIXTURE_SESSION_UUID,  run[:session_id]
      assert_nil run[:iteration_id]
      assert_nil run[:lane]
    end
  end

  def test_architect_run_has_space_id
    with_staged_session_root do |root|
      import!(claude_projects_root: root)
      space = conn[:spaces].first
      run   = conn[:runs].where(role: "architect").first
      assert_equal space[:id], run[:space_id]
    end
  end

  def test_architect_run_has_conversation_with_messages
    with_staged_session_root do |root|
      import!(claude_projects_root: root)
      run = conn[:runs].where(role: "architect").first
      refute_nil run[:conversation_id]
      msg_count = conn[:messages].where(conversation_id: run[:conversation_id]).count
      assert msg_count >= 1, "expected ≥1 message in architect run conversation"
    end
  end

  def test_architect_run_idempotency
    with_staged_session_root do |root|
      import!(claude_projects_root: root)
      counts1 = snapshot_counts
      import!(claude_projects_root: root)
      counts2 = snapshot_counts
      assert_equal counts1, counts2,
        "second import must not add rows: #{counts1.inspect} vs #{counts2.inspect}"
    end
  end

  def test_architect_run_idempotency_message_count_stable
    with_staged_session_root do |root|
      import!(claude_projects_root: root)
      run_id    = conn[:runs].where(role: "architect").first[:id]
      conv_id   = conn[:runs].where(id: run_id).first[:conversation_id]
      msg_count = conn[:messages].where(conversation_id: conv_id).count

      import!(claude_projects_root: root)
      new_conv_id   = conn[:runs].where(id: run_id).first[:conversation_id]
      new_msg_count = conn[:messages].where(conversation_id: new_conv_id).count

      assert_equal msg_count, new_msg_count,
        "message count must be identical after re-import of architect run"
    end
  end

  def test_absent_claude_projects_root_succeeds_with_zero_architect_runs
    Dir.mktmpdir("space_importer_absent") do |root|
      # no subdir matching mangle(FIXTURE_DIR) — should succeed, 0 architect runs
      space = import!(claude_projects_root: root)
      refute_nil space
      assert_equal 0, conn[:runs].where(role: "architect").count
    end
  end

  def test_absent_project_subdir_does_not_affect_builder_runs
    Dir.mktmpdir("space_importer_absent2") do |root|
      import!(claude_projects_root: root)
      runs = conn[:runs].where(role: "builder").all
      assert_equal 1, runs.length
    end
  end

  # ── occurred_at — architect runs ─────────────────────────────────────────────

  def test_architect_run_occurred_at_from_first_jsonl_timestamp
    with_staged_session_root do |root|
      import!(claude_projects_root: root)
      run = conn[:runs].where(role: "architect").first
      refute_nil run[:occurred_at], "occurred_at must be populated from session jsonl"
      # Fixture's first timestamp is 2026-06-28T00:00:01.000Z
      expected = Time.iso8601("2026-06-28T00:00:01.000Z").utc
      assert_equal expected, run[:occurred_at].utc
    end
  end

  def test_architect_run_occurred_at_not_import_time
    with_staged_session_root do |root|
      before = Time.now - 1
      import!(claude_projects_root: root)
      run = conn[:runs].where(role: "architect").first
      # occurred_at must be the session timestamp (2026-06-28), not Time.now
      refute run[:occurred_at].utc >= before,
        "occurred_at must come from the jsonl, not import time"
    end
  end

  # ── occurred_at — iterations ──────────────────────────────────────────────────

  def test_iteration_occurred_at_nil_when_not_a_git_repo
    # FIXTURE_DIR is not a git repo; freeze_sha abc123def456 cannot resolve
    import!
    iters = conn[:iterations].all
    iters.each do |iter|
      assert_nil iter[:occurred_at],
        "occurred_at must be nil when space is not a git repo (ordinal #{iter[:ordinal]})"
    end
  end

  def test_iteration_occurred_at_nil_when_freeze_sha_blank
    # second-iteration has freeze_sha: '' — must not raise
    import!
    iter2 = conn[:iterations].where(ordinal: 2).first
    assert_nil iter2[:occurred_at]
  end

  # ── git_commit_time helper (unit) ────────────────────────────────────────────

  def test_git_commit_time_nil_for_nil_sha
    assert_nil @importer.send(:git_commit_time, FIXTURE_DIR, nil)
  end

  def test_git_commit_time_nil_for_blank_sha
    assert_nil @importer.send(:git_commit_time, FIXTURE_DIR, "")
  end

  def test_git_commit_time_nil_for_non_git_dir
    Dir.mktmpdir("not_a_git") do |dir|
      assert_nil @importer.send(:git_commit_time, dir, "abc123")
    end
  end

  def test_git_commit_time_returns_time_for_real_commit
    Dir.mktmpdir("git_fixture") do |dir|
      system("git", "-C", dir, "init", "-q",
             "--initial-branch=main", exception: false) ||
        system("git", "-C", dir, "init", "-q", exception: false)
      system("git", "-C", dir, "config", "user.email", "test@test.com", exception: false)
      system("git", "-C", dir, "config", "user.name", "Test", exception: false)
      File.write(File.join(dir, "x"), "x")
      system("git", "-C", dir, "add", ".", exception: false)
      system("git", "-C", dir, "commit", "-m", "init", "--no-gpg-sign", exception: false)
      sha = `git -C #{dir} rev-parse HEAD`.strip
      result = @importer.send(:git_commit_time, dir, sha)
      assert_kind_of Time, result
    end
  end

  # ── git_commit_info helper (unit) ────────────────────────────────────────────

  def test_git_commit_info_nil_for_nil_sha
    assert_nil @importer.send(:git_commit_info, FIXTURE_DIR, nil)
  end

  def test_git_commit_info_nil_for_blank_sha
    assert_nil @importer.send(:git_commit_info, FIXTURE_DIR, "")
  end

  def test_git_commit_info_nil_for_non_git_dir
    Dir.mktmpdir("not_a_git_info") do |dir|
      assert_nil @importer.send(:git_commit_info, dir, "abc123")
    end
  end

  def test_git_commit_info_returns_time_and_offset_for_real_commit
    Dir.mktmpdir("git_info_fixture") do |dir|
      system("git", "-C", dir, "init", "-q",
             "--initial-branch=main", exception: false) ||
        system("git", "-C", dir, "init", "-q", exception: false)
      system("git", "-C", dir, "config", "user.email", "test@test.com", exception: false)
      system("git", "-C", dir, "config", "user.name", "Test", exception: false)
      File.write(File.join(dir, "x"), "x")
      system("git", "-C", dir, "add", ".", exception: false)
      commit_env = { "GIT_COMMITTER_DATE" => "2026-01-01T12:00:00-0600",
                     "GIT_AUTHOR_DATE"    => "2026-01-01T12:00:00-0600",
                     "PATH"               => ENV.fetch("PATH") }
      system(commit_env, "git", "-C", dir, "commit", "-m", "init", "--no-gpg-sign",
             exception: false)
      sha = `git -C #{dir} rev-parse HEAD`.strip
      result = @importer.send(:git_commit_info, dir, sha)
      assert_kind_of Array, result
      assert_kind_of Time,    result.first
      assert result.first.utc?, "time must be UTC"
      assert_equal(-21600,    result.last, "offset must be -21600 for -0600 commit")
    end
  end

  # ── spaces.git_utc_offset ────────────────────────────────────────────────────

  def test_space_git_utc_offset_populated_from_head_commit
    Dir.mktmpdir("git_space_offset") do |dir|
      system("git", "-C", dir, "init", "-q",
             "--initial-branch=main", exception: false) ||
        system("git", "-C", dir, "init", "-q", exception: false)
      system("git", "-C", dir, "config", "user.email", "test@test.com", exception: false)
      system("git", "-C", dir, "config", "user.name", "Test", exception: false)

      yaml = <<~YAML
        id: git-offset-space
        title: Git Offset Space
        status: active
        architect:
          status: active
          iterations: []
      YAML
      File.write(File.join(dir, "space.yaml"), yaml)
      system("git", "-C", dir, "add", ".", exception: false)
      commit_env = { "GIT_COMMITTER_DATE" => "2026-01-01T12:00:00-0600",
                     "GIT_AUTHOR_DATE"    => "2026-01-01T12:00:00-0600",
                     "PATH"               => ENV.fetch("PATH") }
      system(commit_env, "git", "-C", dir, "commit", "-m", "init", "--no-gpg-sign",
             exception: false)

      @importer.import!(dir, user: @user)
      space = conn[:spaces].where(slug: "git-offset-space").first
      assert_equal(-21600, space[:git_utc_offset])
    end
  end

  def test_space_git_utc_offset_nil_when_not_a_git_repo
    # FIXTURE_DIR is inside the worktree repo, so we use a fresh temp dir
    # outside any git tree to guarantee "not a git repo" semantics.
    Dir.mktmpdir("not_git_space") do |dir|
      yaml = <<~YAML
        id: non-git-space
        title: Non Git Space
        status: active
        architect:
          status: active
          iterations: []
      YAML
      File.write(File.join(dir, "space.yaml"), yaml)
      @importer.import!(dir, user: @user)
      space = conn[:spaces].where(slug: "non-git-space").first
      assert_nil space[:git_utc_offset], "git_utc_offset must be nil for non-git source_path"
    end
  end

  # ── iterations.occurred_at_utc_offset ────────────────────────────────────────

  def test_iteration_occurred_at_utc_offset_from_freeze_sha
    Dir.mktmpdir("git_iter_offset") do |dir|
      system("git", "-C", dir, "init", "-q",
             "--initial-branch=main", exception: false) ||
        system("git", "-C", dir, "init", "-q", exception: false)
      system("git", "-C", dir, "config", "user.email", "test@test.com", exception: false)
      system("git", "-C", dir, "config", "user.name", "Test", exception: false)
      File.write(File.join(dir, "x"), "x")
      system("git", "-C", dir, "add", ".", exception: false)
      commit_env = { "GIT_COMMITTER_DATE" => "2026-01-01T12:00:00-0600",
                     "GIT_AUTHOR_DATE"    => "2026-01-01T12:00:00-0600",
                     "PATH"               => ENV.fetch("PATH") }
      system(commit_env, "git", "-C", dir, "commit", "-m", "init", "--no-gpg-sign",
             exception: false)
      sha = `git -C #{dir} rev-parse HEAD`.strip

      yaml = <<~YAML
        id: iter-offset-space
        title: Iter Offset Space
        status: active
        architect:
          status: active
          iterations:
          - name: test-iter
            ordinal: 1
            file: architecture/I01.md
            freeze_sha: #{sha}
            verdict: continue
            lanes: []
      YAML
      File.write(File.join(dir, "space.yaml"), yaml)

      @importer.import!(dir, user: @user)
      iter = conn[:iterations].where(ordinal: 1).first
      assert_equal(-21600, iter[:occurred_at_utc_offset])
    end
  end

  def test_iteration_occurred_at_utc_offset_nil_when_sha_unresolvable
    # Fixture freeze_sha abc123def456 cannot be resolved in any repo — offset must be nil
    import!
    conn[:iterations].all.each do |iter|
      assert_nil iter[:occurred_at_utc_offset],
        "occurred_at_utc_offset must be nil when freeze_sha cannot resolve (ordinal #{iter[:ordinal]})"
    end
  end

  def test_iteration_occurred_at_utc_offset_nil_when_freeze_sha_blank
    import!
    iter2 = conn[:iterations].where(ordinal: 2).first
    assert_nil iter2[:occurred_at_utc_offset]
  end

  # ── occurred_at sub-second precision ─────────────────────────────────────────

  def test_architect_run_occurred_at_has_sub_second_precision
    with_staged_session_root do |root|
      import!(claude_projects_root: root)
      run = conn[:runs].where(role: "architect").first
      # Fixture first timestamp: 2026-06-28T00:00:01.000Z — must preserve .000 fraction
      assert_includes run[:occurred_at].utc.iso8601(6), "00:00:01.000000",
        "occurred_at must retain millisecond fraction, not truncate to whole seconds"
    end
  end

  private

  def snapshot_counts
    %i[spaces iterations artifacts runs conversations messages].each_with_object({}) do |t, h|
      h[t] = conn[t].count
    end
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

class VerifyWorktreeScriptTest < Space::ArchitectTest
  SCRIPT = File.expand_path("../script/verify-worktree-in-container", __dir__)

  def setup_repo
    dir = Dir.mktmpdir("vw-test-repo")
    system("git", "init", dir, out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "config", "user.name", "Test", out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL)
    File.write(File.join(dir, "seed.txt"), "seed")
    system("git", "-C", dir, "add", "seed.txt", out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "commit", "-m", "seed", out: File::NULL, err: File::NULL)
    dir
  end

  def test_success_and_idempotent
    repo = setup_repo

    stdout1, _, status1 = Open3.capture3("ruby", SCRIPT, repo)
    assert_equal 0, status1.exitstatus, "first run failed: #{stdout1}"
    assert_match(/\AWORKTREE-OK /, stdout1)

    stdout2, _, status2 = Open3.capture3("ruby", SCRIPT, repo)
    assert_equal 0, status2.exitstatus, "second run failed: #{stdout2}"
    assert_match(/\AWORKTREE-OK /, stdout2)
  ensure
    FileUtils.rm_rf(repo) if repo
  end

  def test_non_git_path_yields_failure
    dir = Dir.mktmpdir("vw-not-a-repo")
    file_path = File.join(dir, "not-a-repo.txt")
    File.write(file_path, "not a repo")

    stdout, stderr, status = Open3.capture3("ruby", SCRIPT, file_path)
    assert_equal 1, status.exitstatus
    assert_match(/WORKTREE-FAIL/, stdout + stderr)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

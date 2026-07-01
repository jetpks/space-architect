# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

class OciBuilderTest < Space::ArchitectTest
  def setup
    @dir = Dir.mktmpdir("oci-builder-test")
    git!("init", "-b", "main")
    git!("config", "user.email", "test@example.com")
    git!("config", "user.name", "Test User")
    File.write(File.join(@dir, "space.yaml"), "id: 20260630-test\ntitle: Test\n")
    git!("add", ".")
    git!("commit", "-m", "init")
    @space = Space::Core::Space.new(@dir, "id" => "20260630-test", "title" => "Test")
    @out_dir = Pathname.new(@dir).join("build", "oci")
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def test_version_returns_12char_sha_for_clean_tree
    expected, _, = Open3.capture3("git", "-C", @dir, "rev-parse", "--short=12", "HEAD")
    builder = Space::Core::OciBuilder.new(space: @space, output_dir: @out_dir)

    assert_equal expected.strip, builder.version
  end

  def test_image_includes_sha_for_clean_tree
    expected_sha, _, = Open3.capture3("git", "-C", @dir, "rev-parse", "--short=12", "HEAD")
    builder = Space::Core::OciBuilder.new(space: @space, output_dir: @out_dir)

    assert_equal "20260630-test:#{expected_sha.strip}", builder.image
  end

  def test_version_ends_with_dirty_for_dirty_tree
    File.write(File.join(@dir, "space.yaml"), "id: 20260630-test\ntitle: Dirty\n")
    builder = Space::Core::OciBuilder.new(space: @space, output_dir: @out_dir)

    assert_match(/-dirty\z/, builder.version)
  end

  def test_command_returns_success_with_exact_9_element_argv
    sha, _, = Open3.capture3("git", "-C", @dir, "rev-parse", "--short=12", "HEAD")
    ver = sha.strip
    builder = Space::Core::OciBuilder.new(space: @space, output_dir: @out_dir)
    result = builder.command

    assert result.success?
    assert_equal [
      "container", "build",
      "-f", @out_dir.join("Dockerfile").to_s,
      "-t", "20260630-test:#{ver}",
      "-t", "20260630-test:latest",
      @dir
    ], result.value!
  end

  def test_command_returns_failure_when_no_git_repo
    non_git = Dir.mktmpdir("no-git")
    space = Space::Core::Space.new(non_git, "id" => "20260630-nogit", "title" => "NoGit")
    builder = Space::Core::OciBuilder.new(space: space, output_dir: Pathname.new(non_git).join("build", "oci"))
    result = builder.command

    assert result.failure?
    assert_match(/not a git repository/, result.failure)
  ensure
    FileUtils.rm_rf(non_git)
  end

  def test_command_returns_failure_when_no_commits
    empty_git = Dir.mktmpdir("empty-git")
    system("git", "-C", empty_git, "init", "-b", "main", out: File::NULL, err: File::NULL)
    space = Space::Core::Space.new(empty_git, "id" => "20260630-empty", "title" => "Empty")
    builder = Space::Core::OciBuilder.new(space: space, output_dir: Pathname.new(empty_git).join("build", "oci"))
    result = builder.command

    assert result.failure?
    assert_match(/cannot compute a version tag/, result.failure)
  ensure
    FileUtils.rm_rf(empty_git)
  end

  private

  def git!(*args)
    out, err, status = Open3.capture3("git", "-C", @dir, *args)
    raise "git #{args.join(' ')} failed: #{[out, err].join(' ').strip}" unless status.success?
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "async"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "space_architect/pristine"

module TestHelpers
  Shell = SpaceArchitect::Pristine::Shell

  # Run the given block in a fresh temp directory that is the
  # effective HOME for XDG resolution. Yields (env_hash, home_dir).
  def with_temp_home
    Dir.mktmpdir("repo-tender-test-") do |home|
      env = {
        "HOME" => home,
        "XDG_CONFIG_HOME" => File.join(home, ".config"),
        "XDG_STATE_HOME" => File.join(home, ".local", "state"),
        "XDG_CACHE_HOME" => File.join(home, ".cache")
      }
      env.each { |k, v| FileUtils.mkdir_p(v) }
      yield(env, home)
    end
  end

  # Wrap a temp HOME with XDG defaults created. Yields the
  # XDG-overridden environment hash plus a fresh Paths instance.
  def with_paths(base_dir: nil)
    with_temp_home do |env, _|
      yield(env, SpaceArchitect::Pristine::Paths.new(environment: env, base_dir: base_dir))
    end
  end

  # Run the block inside a Sync{} task (Shell requires one).
  def in_async(&block)
    Sync(&block)
  end

  # Set up a real bare git remote + a working clone on disk.
  # The bare remote's default branch is `trunk` (per gate G5, the test
  # must NOT assume `main`). Yields paths to the bare and the clone.
  def with_trunk_repo
    Dir.mktmpdir("repo-tender-git-") do |dir|
      bare = File.join(dir, "bare.git")
      clone = File.join(dir, "clone")
      system("git", "init", "-b", "trunk", "--bare", bare, exception: true, out: File::NULL)
      system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone, exception: true, out: File::NULL)
      in_async do
        Shell.run("git", "remote", "add", "origin", bare, chdir: clone)
        Shell.run("git", "config", "user.email", "test@example.com", chdir: clone)
        Shell.run("git", "config", "user.name", "Test", chdir: clone)
        yield(bare, clone)
      end
    end
  end

  # Make an initial commit on a clone and push it to its bare remote,
  # establishing a real "trunk" branch. Returns nothing; the caller
  # operates on the clone in the same `in_async` block.
  def seed_initial_commit(clone, content: "hello\n", filename: "README.md", message: "initial")
    in_async do
      File.write(File.join(clone, filename), content)
      Shell.run("git", "add", ".", chdir: clone)
      Shell.run("git", "commit", "-qm", message, chdir: clone)
      Shell.run("git", "push", "-q", "-u", "origin", "trunk", chdir: clone)
    end
  end

  # Set up a real EMPTY bare git remote + a working clone with zero commits.
  # The bare remote's default branch is `trunk` (consistent with
  # with_trunk_repo). The clone has an unborn HEAD — no commits exist
  # anywhere. Yields paths to the bare and the clone inside an in_async
  # block (Shell.run is available throughout).
  def with_empty_repo
    Dir.mktmpdir("repo-tender-empty-") do |dir|
      bare = File.join(dir, "bare.git")
      clone = File.join(dir, "clone")
      system("git", "init", "-b", "trunk", "--bare", bare, exception: true, out: File::NULL)
      system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone, exception: true, out: File::NULL)
      in_async do
        Shell.run("git", "remote", "add", "origin", bare, chdir: clone)
        Shell.run("git", "config", "user.email", "test@example.com", chdir: clone)
        Shell.run("git", "config", "user.name", "Test", chdir: clone)
        yield(bare, clone)
      end
    end
  end

  # Push a commit to a bare remote from a new seeder clone.
  # Used in GB3 tests to simulate the remote gaining its first commit(s)
  # after an initially empty clone is already set up.
  def push_first_commit_to_bare(bare, content: "hello\n", filename: "README.md", message: "first commit")
    Dir.mktmpdir("repo-tender-seeder-") do |sdir|
      seeder = File.join(sdir, "seeder")
      system("git", "-c", "init.defaultBranch=trunk", "init", "-q", seeder, exception: true, out: File::NULL)
      in_async do
        Shell.run("git", "remote", "add", "origin", bare, chdir: seeder)
        Shell.run("git", "config", "user.email", "test@example.com", chdir: seeder)
        Shell.run("git", "config", "user.name", "Test", chdir: seeder)
        File.write(File.join(seeder, filename), content)
        Shell.run("git", "add", ".", chdir: seeder)
        Shell.run("git", "commit", "-qm", message, chdir: seeder)
        Shell.run("git", "push", "-q", "origin", "trunk", chdir: seeder)
      end
    end
  end
end

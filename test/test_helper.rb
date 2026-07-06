# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "minitest/autorun"
require "mutant/minitest/coverage"
require_relative "../lib/space_architect"

# Git fixture templates: process-wide singletons. Tests copy .git from these
# templates instead of paying for git init + config + add + commit per call.
module Space::GitFixtureTemplate
  # Empty repo (init + config only) — used where the test controls its own first commit.
  def self.dir
    @dir ||= begin
      d = Dir.mktmpdir("architect-git-template")
      system("git", "-C", d, "init", "-q", "-b", "main", exception: false) ||
        system("git", "-C", d, "init", "-q")
      system("git", "-C", d, "config", "user.name", "Test Builder")
      system("git", "-C", d, "config", "user.email", "test@example.com")
      d
    end
  end

  # Repo with one README.md commit — repo fixture template.
  def self.repo_dir
    @repo_dir ||= begin
      d = Dir.mktmpdir("architect-repo-template")
      system("git", "-C", d, "init", "-q", "-b", "main", exception: false) ||
        system("git", "-C", d, "init", "-q")
      system("git", "-C", d, "config", "user.name", "Test Builder")
      system("git", "-C", d, "config", "user.email", "test@example.com")
      File.write(File.join(d, "README.md"), "# repo\n")
      system("git", "-C", d, "add", "README.md")
      system("git", "-C", d, "commit", "-q", "-m", "init")
      d
    end
  end

  # Space repo with a specific space.yaml content committed — memoized per content.
  def self.space_dir(yaml)
    @space_dirs ||= {}
    @space_dirs[yaml] ||= begin
      d = Dir.mktmpdir("architect-space-template")
      system("git", "-C", d, "init", "-q", "-b", "main", exception: false) ||
        system("git", "-C", d, "init", "-q")
      system("git", "-C", d, "config", "user.name", "Test Builder")
      system("git", "-C", d, "config", "user.email", "test@example.com")
      File.write(File.join(d, "space.yaml"), yaml)
      system("git", "-C", d, "add", "space.yaml")
      system("git", "-C", d, "commit", "-q", "-m", "init")
      d
    end
  end
end

class Space::ArchitectTest < Minitest::Test
  # Seeds `dir` (an existing, empty directory) with a pre-initialized,
  # pre-configured git repo by copying the process-wide template's .git dir.
  def seed_git_repo(dir)
    FileUtils.cp_r(File.join(Space::GitFixtureTemplate.dir, ".git"), dir)
  end
  def invoke(*argv)
    out = StringIO.new
    err = StringIO.new
    Space::Architect::CLI.call(argv.flatten, out, err)
    [out.string, err.string]
  end
  def with_env(vars)
    original = vars.each_key.to_h { |key| [key, ENV[key]] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    original&.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  def temp_env
    root = Dir.mktmpdir("project-spaces-test")
    {
      root: root,
      env: {
        "HOME" => File.join(root, "home"),
        "XDG_CONFIG_HOME" => File.join(root, "xdg-config"),
        "XDG_STATE_HOME" => File.join(root, "xdg-state")
      }
    }
  end

  def fixed_time
    Time.new(2026, 5, 31, 13, 48, 0, "-06:00")
  end

  def build_store(env:, now: -> { fixed_time })
    config = Space::Core::Config.new(
      env: env,
      data: { "version" => 1 }
    )
    state = Space::Core::State.new(env: env)
    Space::Core::SpaceStore.new(config: config, state: state, now: now)
  end
end

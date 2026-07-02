# frozen_string_literal: true

require_relative "test_helper"

class CorePathsTest < Space::ArchitectTest
  def test_exact_home_contracts_to_tilde
    env = { "HOME" => "/fake/home" }
    assert_equal "~", Space::Core::Paths.contract("/fake/home", env: env)
  end

  def test_home_prefix_contracts_to_tilde_slash_rest
    env = { "HOME" => "/fake/home" }
    assert_equal "~/projects/foo", Space::Core::Paths.contract("/fake/home/projects/foo", env: env)
  end

  def test_non_home_path_unchanged
    env = { "HOME" => "/fake/home" }
    assert_equal "/other/path", Space::Core::Paths.contract("/other/path", env: env)
  end

  def test_env_injected_home_used_not_process_home
    env = { "HOME" => "/injected/home" }
    path = "/injected/home/file.md"
    assert_equal "~/file.md", Space::Core::Paths.contract(path, env: env)
  end

  def test_realpathed_home_also_contracts
    Dir.mktmpdir("paths-test") do |dir|
      real = File.join(dir, "realhome")
      FileUtils.mkdir_p(real)
      symlinked = File.join(dir, "symhome")
      File.symlink(real, symlinked)
      env = { "HOME" => symlinked }
      # path expressed via realpath of home should contract even though HOME is the symlink
      real_path = File.realpath(symlinked)
      assert_equal "~/foo", Space::Core::Paths.contract(File.join(real_path, "foo"), env: env)
    end
  end

  def test_accepts_pathname_object
    env = { "HOME" => "/fake/home" }
    assert_equal "~/bar", Space::Core::Paths.contract(Pathname.new("/fake/home/bar"), env: env)
  end
end

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

  # content_tree — recursive walk, dotfiles included, self-entry excluded

  def test_content_tree_includes_dotfiles_and_dot_directory_contents
    Dir.mktmpdir("paths-test") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hidden"))
      File.write(File.join(dir, ".hidden", "inner.txt"), "x")
      File.write(File.join(dir, ".dotfile"), "y")
      File.write(File.join(dir, "plain.txt"), "z")

      found = Space::Core::Paths.content_tree(dir).map { |p| p.to_s }
      assert_includes found, File.join(dir, ".dotfile")
      assert_includes found, File.join(dir, ".hidden", "inner.txt")
      assert_includes found, File.join(dir, "plain.txt")
    end
  end

  def test_content_tree_excludes_dot_and_dotdot_self_entries
    Dir.mktmpdir("paths-test") do |dir|
      File.write(File.join(dir, "plain.txt"), "z")

      basenames = Space::Core::Paths.content_tree(dir).map { |p| File.basename(p) }
      refute_includes basenames, "."
      refute_includes basenames, ".."
    end
  end

  def test_content_tree_accepts_pathname_root
    Dir.mktmpdir("paths-test") do |dir|
      File.write(File.join(dir, "plain.txt"), "z")

      found = Space::Core::Paths.content_tree(Pathname.new(dir)).map { |p| p.to_s }
      assert_includes found, File.join(dir, "plain.txt")
    end
  end

  def test_content_tree_empty_dir_returns_empty
    Dir.mktmpdir("paths-test") { |dir| assert_empty Space::Core::Paths.content_tree(dir) }
  end

  # layout_children — one level, dotfiles excluded

  def test_layout_children_excludes_dotfiles
    Dir.mktmpdir("paths-test") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".git"))
      File.write(File.join(dir, ".DS_Store"), "junk")
      FileUtils.mkdir_p(File.join(dir, "I01-first"))

      names = Space::Core::Paths.layout_children(dir).map { |p| p.basename.to_s }
      assert_equal ["I01-first"], names
    end
  end

  def test_layout_children_includes_plain_entries
    Dir.mktmpdir("paths-test") do |dir|
      FileUtils.mkdir_p(File.join(dir, "a"))
      FileUtils.mkdir_p(File.join(dir, "b"))

      names = Space::Core::Paths.layout_children(dir).map { |p| p.basename.to_s }.sort
      assert_equal ["a", "b"], names
    end
  end

  def test_layout_children_accepts_pathname
    Dir.mktmpdir("paths-test") do |dir|
      FileUtils.mkdir_p(File.join(dir, "a"))

      names = Space::Core::Paths.layout_children(Pathname.new(dir)).map { |p| p.basename.to_s }
      assert_equal ["a"], names
    end
  end

  # touch_match? — single-glob predicate behind in_touch_set?

  def test_touch_match_matches_dotfile_segment_under_trailing_double_star
    assert Space::Core::Paths.touch_match?("gems/my-gem/**", "gems/my-gem/.github/workflows/ci.yml")
  end

  def test_touch_match_rejects_dotfile_outside_touch_set
    refute Space::Core::Paths.touch_match?("gems/my-gem/**", ".github/workflows/release.yml")
  end

  def test_touch_match_single_star_does_not_cross_slash
    assert Space::Core::Paths.touch_match?("lib/*.rb", "lib/foo.rb")
    refute Space::Core::Paths.touch_match?("lib/*.rb", "lib/nested/foo.rb")
  end
end

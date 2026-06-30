# frozen_string_literal: true

require_relative "../test_helper"

class OciPackerTest < Space::ArchitectTest
  def test_generate_creates_dockerfile_entrypoint_and_dockerignore
    with_space do |space, out_dir|
      result = Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate

      assert result.success?, "expected Success, got: #{result.inspect}"
      assert_path_exists File.join(out_dir, "Dockerfile")
      assert_path_exists File.join(out_dir, "entrypoint.sh")
      assert_path_exists File.join(out_dir, ".dockerignore")
    end
  end

  def test_generate_returns_output_dir_as_value
    with_space do |space, out_dir|
      result = Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate

      assert result.success?
      assert_equal Pathname.new(out_dir), result.value!
    end
  end

  def test_dockerfile_uses_ruby_405_base_image
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      assert_match(/^FROM ruby:4\.0\.5/, dockerfile)
    end
  end

  def test_dockerfile_installs_git_and_curl
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      assert_match(/apt-get install/, dockerfile)
      assert_match(/\bgit\b/, dockerfile)
      assert_match(/\bcurl\b/, dockerfile)
    end
  end

  def test_dockerfile_installs_claude_code_cli
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      assert_match(%r{curl -fsSL https://claude\.ai/install\.sh}, dockerfile)
    end
  end

  def test_dockerfile_copies_space_to_slash_space
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      assert_match(/^COPY \. \/space$/, dockerfile)
    end
  end

  def test_dockerfile_installs_space_architect_gem
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      assert_match(/space-architect/, dockerfile)
      assert_match(/gem install/, dockerfile)
    end
  end

  def test_dockerfile_includes_space_id_in_comment
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      assert_match(space.id, dockerfile)
    end
  end

  def test_dockerfile_sets_workdir_to_slash_space
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      assert_match(/^WORKDIR \/space$/, dockerfile)
    end
  end

  def test_dockerfile_contains_no_secret_values
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      # Env var NAMES are allowed in comments; actual values are not.
      # A real Anthropic key starts with "sk-ant-"
      refute_match(/sk-ant-/, dockerfile, "must not contain Anthropic API key prefix")
      # No ENV instruction that assigns a value (placeholder <...> is fine, actual tokens are not)
      refute_match(/^ENV ANTHROPIC_API_KEY=(?!<)/, dockerfile,       "must not bake ANTHROPIC_API_KEY")
      refute_match(/^ENV CLAUDE_CODE_OAUTH_TOKEN=(?!<)/, dockerfile, "must not bake CLAUDE_CODE_OAUTH_TOKEN")
    end
  end

  def test_entrypoint_sets_safe_directory_and_execs
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      entrypoint = File.read(File.join(out_dir, "entrypoint.sh"))

      assert_match(%r{^#!/bin/bash}, entrypoint)
      assert_match(/git config --global --add safe\.directory '\*'/, entrypoint)
      assert_match(/exec/, entrypoint)
    end
  end

  def test_entrypoint_is_executable
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      mode = File.stat(File.join(out_dir, "entrypoint.sh")).mode

      assert mode & 0o111 != 0, "entrypoint.sh should be executable"
    end
  end

  def test_dockerignore_excludes_git_and_secrets
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerignore = File.read(File.join(out_dir, ".dockerignore"))

      assert_match(/^\.git$/, dockerignore)
      assert_match(/\.env/, dockerignore)
      assert_match(/\.key/, dockerignore)
      assert_match(/\.pem/, dockerignore)
    end
  end

  def test_dockerignore_excludes_build_scratch
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerignore = File.read(File.join(out_dir, ".dockerignore"))

      assert_match(/^build\//, dockerignore)
      assert_match(/^tmp\//, dockerignore)
    end
  end

  def test_generate_is_deterministic_same_files_twice
    with_space do |space, tmp|
      out1 = File.join(tmp, "run1")
      out2 = File.join(tmp, "run2")

      Space::Core::OciPacker.new(space: space, output_dir: out1).generate
      Space::Core::OciPacker.new(space: space, output_dir: out2).generate

      %w[Dockerfile entrypoint.sh .dockerignore].each do |filename|
        content1 = File.read(File.join(out1, filename))
        content2 = File.read(File.join(out2, filename))
        assert_equal content1, content2,
                     "#{filename} must be byte-identical across two runs on the same space"
      end
    end
  end

  def test_generated_files_contain_no_absolute_host_paths
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate

      %w[Dockerfile entrypoint.sh .dockerignore].each do |filename|
        content = File.read(File.join(out_dir, filename))
        refute_match(%r{/Users/}, content, "#{filename} must not leak host paths")
        refute_match(%r{/home/}, content,  "#{filename} must not leak host paths")
      end
    end
  end

  def test_generate_creates_output_dir_if_absent
    with_space do |space, tmp|
      out_dir = File.join(tmp, "nested", "oci")

      result = Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate

      assert result.success?
      assert_path_exists out_dir
    end
  end

  private

  def with_space
    setup = temp_env
    store = build_store(env: setup.fetch(:env))
    space = store.create("Pack Test Space", git: false).value!
    out_dir = Dir.mktmpdir("oci-packer-test")
    yield space, out_dir
  ensure
    FileUtils.rm_rf(out_dir) if out_dir && File.directory?(out_dir)
    FileUtils.rm_rf(setup[:root]) if setup
  end
end

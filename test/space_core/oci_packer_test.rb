# frozen_string_literal: true

require_relative "../test_helper"

class OciPackerTest < Space::ArchitectTest
  def test_generate_creates_dockerfile_entrypoint_and_dockerignore
    with_space do |space, out_dir|
      result = Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate

      assert result.success?, "expected Success, got: #{result.inspect}"
      assert_path_exists File.join(out_dir, "Dockerfile")
      assert_path_exists File.join(out_dir, "entrypoint.sh")
      assert_path_exists File.join(out_dir, "Dockerfile.dockerignore")
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

  def test_entrypoint_seeds_a_default_git_identity_when_unset
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      entrypoint = File.read(File.join(out_dir, "entrypoint.sh"))

      # Only when unset (so a mounted/-e identity wins), so the in-guest architect
      # loop's commits — and the worktree harness — don't die on "Author identity unknown".
      assert_match(/git config --global --get user\.name .* \|\| git config --global user\.name /, entrypoint)
      assert_match(/git config --global --get user\.email .* \|\| git config --global user\.email /, entrypoint)
    end
  end

  def test_entrypoint_is_executable
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      mode = File.stat(File.join(out_dir, "entrypoint.sh")).mode

      assert mode & 0o111 != 0, "entrypoint.sh should be executable"
    end
  end

  def test_dockerignore_bakes_git_and_hides_secrets
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerignore = File.read(File.join(out_dir, "Dockerfile.dockerignore"))

      refute_match(/^\.git$/, dockerignore)
      assert_match(/\.env/, dockerignore)
      assert_match(/\.key/, dockerignore)
      assert_match(/\.pem/, dockerignore)
    end
  end

  def test_dockerignore_excludes_build_scratch
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerignore = File.read(File.join(out_dir, "Dockerfile.dockerignore"))

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

      %w[Dockerfile entrypoint.sh Dockerfile.dockerignore].each do |filename|
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

      %w[Dockerfile entrypoint.sh Dockerfile.dockerignore].each do |filename|
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

  def test_no_provision_dockerfile_contains_no_run_space_provision_line
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      refute_match(%r{^RUN /space/}, dockerfile)
    end
  end

  def test_provision_scripts_emitted_in_declared_order_after_copy_before_workdir
    with_provisioned_space(provision: ["scripts/a.sh", "scripts/b.sh"]) do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      assert_match(/^RUN \/space\/scripts\/a\.sh$/, dockerfile)
      assert_match(/^RUN \/space\/scripts\/b\.sh$/, dockerfile)

      copy_pos   = dockerfile.index("COPY . /space")
      run_a_pos  = dockerfile.index("RUN /space/scripts/a.sh")
      run_b_pos  = dockerfile.index("RUN /space/scripts/b.sh")
      workdir_pos = dockerfile.rindex("WORKDIR /space")

      assert copy_pos   < run_a_pos,  "RUN /space/a must come after COPY . /space"
      assert run_a_pos  < run_b_pos,  "RUN /space/a must come before RUN /space/b"
      assert run_b_pos  < workdir_pos, "RUN /space/b must come before WORKDIR /space"
    end
  end

  def test_missing_provision_script_returns_failure_and_writes_no_dockerfile
    with_provisioned_space(provision: ["scripts/missing.sh"], create_scripts: false) do |space, out_dir|
      result = Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate

      assert result.failure?
      assert_match(/scripts\/missing\.sh/, result.failure.to_s)
      refute_path_exists File.join(out_dir, "Dockerfile")
    end
  end

  def test_absolute_provision_path_returns_failure_and_writes_no_dockerfile
    with_space do |space, out_dir|
      space.data["pack"] = { "provision" => ["/etc/passwd"] }

      result = Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate

      assert result.failure?
      assert_match(%r{/etc/passwd}, result.failure.to_s)
      refute_path_exists File.join(out_dir, "Dockerfile")
    end
  end

  def test_dotdot_escaping_provision_path_returns_failure_and_writes_no_dockerfile
    with_space do |space, out_dir|
      space.data["pack"] = { "provision" => ["../outside.sh"] }

      result = Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate

      assert result.failure?
      assert_match(%r{\.\./outside\.sh}, result.failure.to_s)
      refute_path_exists File.join(out_dir, "Dockerfile")
    end
  end

  def test_generate_with_provision_is_deterministic
    with_provisioned_space(provision: ["scripts/setup.sh"]) do |space, tmp|
      out1 = File.join(tmp, "run1")
      out2 = File.join(tmp, "run2")

      Space::Core::OciPacker.new(space: space, output_dir: out1).generate
      Space::Core::OciPacker.new(space: space, output_dir: out2).generate

      %w[Dockerfile entrypoint.sh Dockerfile.dockerignore].each do |filename|
        content1 = File.read(File.join(out1, filename))
        content2 = File.read(File.join(out2, filename))
        assert_equal content1, content2,
                     "#{filename} must be byte-identical across two runs with provision"
      end
    end
  end

  def test_dockerfile_contains_profile_d_path_fix
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      assert_match(%r{/etc/profile\.d/space-architect\.sh}, dockerfile)
      assert_match(%r{/usr/local/bundle/bin}, dockerfile)
      assert_match(%r{/root/\.local/bin}, dockerfile)
    end
  end

  def test_persist_paths_rendered_as_volume_flags_in_doc_comment
    with_space do |space, out_dir|
      space.data["pack"] = { "persist" => ["/root/.hermes"] }
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      assert_match(%r{-v [^:]+:/root/\.hermes}, dockerfile)
    end
  end

  def test_no_persist_paths_dockerfile_contains_no_volume_flags
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      refute_match(/-v [^:]+:/, dockerfile)
    end
  end

  def test_relative_persist_path_returns_failure_and_writes_no_dockerfile
    with_space do |space, out_dir|
      space.data["pack"] = { "persist" => ["relative/path"] }

      result = Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate

      assert result.failure?
      assert_match(/relative\/path/, result.failure.to_s)
      refute_path_exists File.join(out_dir, "Dockerfile")
    end
  end

  def test_seed_snapshot_run_emitted_after_provision_before_workdir
    with_provisioned_and_persisted_space(provision: ["scripts/setup.sh"], persist: ["/root/.hermes"]) do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      assert_match(%r{RUN mkdir -p "/opt/space-seed/root/\.hermes"}, dockerfile)
      assert_match(%r{cp -a "/root/\.hermes/\." "/opt/space-seed/root/\.hermes/"}, dockerfile)
      assert_match(%r{2>/dev/null \|\| true}, dockerfile)

      provision_pos = dockerfile.index("RUN /space/scripts/setup.sh")
      seed_pos      = dockerfile.index('RUN mkdir -p "/opt/space-seed/root/.hermes"')
      workdir_pos   = dockerfile.rindex("WORKDIR /space")

      assert provision_pos < seed_pos,    "seed RUN must come after provision RUN"
      assert seed_pos      < workdir_pos, "seed RUN must come before WORKDIR /space"
    end
  end

  def test_no_persist_dockerfile_contains_no_seed_snapshot_run
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      dockerfile = File.read(File.join(out_dir, "Dockerfile"))

      refute_match(%r{space-seed}, dockerfile)
    end
  end

  def test_entrypoint_restore_guard_with_empty_check_and_tolerant_cp
    with_persisted_space(persist: ["/root/.hermes"]) do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      entrypoint = File.read(File.join(out_dir, "entrypoint.sh"))

      assert_match(%r{/opt/space-seed/root/\.hermes}, entrypoint)
      assert_match(/ls -A.*2>\/dev\/null/, entrypoint)

      empty_check_pos = entrypoint.index("ls -A")
      cp_pos          = entrypoint.index("cp -a")
      exec_pos        = entrypoint.index('if [ "$#" -eq 0 ]')

      assert empty_check_pos < cp_pos,   "empty-check must precede cp"
      assert cp_pos          < exec_pos, "restore guard must be before exec branch"

      cp_line = entrypoint.lines.find { |l| l.include?("cp -a") && l.include?("space-seed") }
      assert cp_line, "restore cp line must exist"
      assert_match(/\|\| true/, cp_line, "restore cp must end with || true")
    end
  end

  def test_no_persist_entrypoint_byte_identical_to_base
    with_space do |space, out_dir|
      Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
      entrypoint = File.read(File.join(out_dir, "entrypoint.sh"))

      expected = <<~'SH'
        #!/bin/bash
        set -e
        git config --global --add safe.directory '*'
        git config --global --get user.name >/dev/null 2>&1 || git config --global user.name 'space-architect'
        git config --global --get user.email >/dev/null 2>&1 || git config --global user.email 'architect@localhost'
        if [ "$#" -eq 0 ]; then
          exec bash --login
        else
          exec "$@"
        fi
      SH
      assert_equal expected, entrypoint
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

  def with_provisioned_space(provision:, create_scripts: true)
    setup = temp_env
    store = build_store(env: setup.fetch(:env))
    space = store.create("Provision Test Space", git: false).value!
    if create_scripts
      provision.each do |rel_path|
        script_path = space.path.join(rel_path)
        FileUtils.mkdir_p(script_path.dirname)
        File.write(script_path, "#!/bin/bash\necho provisioned\n")
        File.chmod(0o755, script_path)
      end
    end
    space.data["pack"] = { "provision" => provision }
    out_dir = Dir.mktmpdir("oci-packer-test")
    yield space, out_dir
  ensure
    FileUtils.rm_rf(out_dir) if out_dir && File.directory?(out_dir)
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def with_persisted_space(persist:)
    setup = temp_env
    store = build_store(env: setup.fetch(:env))
    space = store.create("Persist Test Space", git: false).value!
    space.data["pack"] = { "persist" => persist }
    out_dir = Dir.mktmpdir("oci-packer-test")
    yield space, out_dir
  ensure
    FileUtils.rm_rf(out_dir) if out_dir && File.directory?(out_dir)
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def with_provisioned_and_persisted_space(provision:, persist:)
    setup = temp_env
    store = build_store(env: setup.fetch(:env))
    space = store.create("Provision+Persist Test Space", git: false).value!
    provision.each do |rel_path|
      script_path = space.path.join(rel_path)
      FileUtils.mkdir_p(script_path.dirname)
      File.write(script_path, "#!/bin/bash\necho provisioned\n")
      File.chmod(0o755, script_path)
    end
    space.data["pack"] = { "provision" => provision, "persist" => persist }
    out_dir = Dir.mktmpdir("oci-packer-test")
    yield space, out_dir
  ensure
    FileUtils.rm_rf(out_dir) if out_dir && File.directory?(out_dir)
    FileUtils.rm_rf(setup[:root]) if setup
  end
end

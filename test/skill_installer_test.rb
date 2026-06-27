# frozen_string_literal: true

require_relative "test_helper"

class SkillInstallerTest < Space::ArchitectTest
  def setup
    @tmp = temp_env
  end

  def teardown
    FileUtils.rm_rf(@tmp[:root]) if @tmp
  end

  def env
    @tmp[:env]
  end

  # dest_root — per-provider global paths

  def test_dest_root_claude_global
    path = Space::Architect::SkillInstaller.dest_root("claude", project: false, env: env)
    assert_equal File.join(@tmp[:root], "home", ".claude", "skills"), path.to_s
  end

  def test_dest_root_codex_global
    path = Space::Architect::SkillInstaller.dest_root("codex", project: false, env: env)
    assert_equal File.join(@tmp[:root], "home", ".agents", "skills"), path.to_s
  end

  def test_dest_root_opencode_global
    path = Space::Architect::SkillInstaller.dest_root("opencode", project: false, env: env)
    assert_equal File.join(@tmp[:root], "xdg-config", "skills"), path.to_s
  end

  def test_dest_root_pi_global
    path = Space::Architect::SkillInstaller.dest_root("pi", project: false, env: env)
    assert_equal File.join(@tmp[:root], "home", ".pi", "agent", "skills"), path.to_s
  end

  def test_dest_root_pi_global_respects_env_override
    custom = File.join(@tmp[:root], "custom-pi")
    e = env.merge("PI_CODING_AGENT_DIR" => custom)
    path = Space::Architect::SkillInstaller.dest_root("pi", project: false, env: e)
    assert_equal File.join(custom, "skills"), path.to_s
  end

  # dest_root — per-provider project paths

  def test_dest_root_claude_project
    path = Space::Architect::SkillInstaller.dest_root("claude", project: true, env: env, cwd: @tmp[:root])
    assert_equal File.join(@tmp[:root], ".claude", "skills"), path.to_s
  end

  def test_dest_root_codex_project
    path = Space::Architect::SkillInstaller.dest_root("codex", project: true, env: env, cwd: @tmp[:root])
    assert_equal File.join(@tmp[:root], ".agents", "skills"), path.to_s
  end

  def test_dest_root_opencode_project
    path = Space::Architect::SkillInstaller.dest_root("opencode", project: true, env: env, cwd: @tmp[:root])
    assert_equal File.join(@tmp[:root], ".opencode", "skills"), path.to_s
  end

  def test_dest_root_pi_project
    path = Space::Architect::SkillInstaller.dest_root("pi", project: true, env: env, cwd: @tmp[:root])
    assert_equal File.join(@tmp[:root], "skills"), path.to_s
  end

  # dest_root — unknown provider

  def test_dest_root_unknown_provider_raises
    assert_raises(Space::Core::Error) do
      Space::Architect::SkillInstaller.dest_root("unknown", project: false, env: env)
    end
  end

  # source_skills — discovers the bundled skill directories

  def test_source_skills_finds_architect
    names = Space::Architect::SkillInstaller.source_skills.map { |s| s.basename.to_s }
    assert_includes names, "architect"
    assert_includes names, "architect-research"
    assert_includes names, "architect-vocabulary"
  end

  # install — copies skills to dest

  def test_install_copies_all_skills
    result = Space::Architect::SkillInstaller.install("claude", project: false, force: false, env: env)
    skills = result[:skills]
    names = skills.map { |s| s[:name] }
    assert_includes names, "architect"
    assert_includes names, "architect-research"
    assert_includes names, "architect-vocabulary"

    architect_dest = result[:dest_root].join("architect")
    assert architect_dest.join("SKILL.md").exist?
    assert architect_dest.join("dispatch.md").exist?
    assert architect_dest.join("research.md").exist?

    research_dest = result[:dest_root].join("architect-research")
    assert research_dest.join("SKILL.md").exist?
    assert research_dest.join("lanes.md").exist?

    vocabulary_dest = result[:dest_root].join("architect-vocabulary")
    assert vocabulary_dest.join("SKILL.md").exist?
  end

  def test_install_reports_installed_for_new_skills
    result = Space::Architect::SkillInstaller.install("claude", project: false, force: false, env: env)
    assert result[:skills].all? { |s| s[:action] == :installed }
  end

  def test_install_unchanged_when_same_content
    Space::Architect::SkillInstaller.install("claude", project: false, force: false, env: env)
    result = Space::Architect::SkillInstaller.install("claude", project: false, force: false, env: env)
    assert result[:skills].all? { |s| s[:action] == :unchanged }
  end

  def test_install_raises_when_dest_differs_without_force
    Space::Architect::SkillInstaller.install("claude", project: false, force: false, env: env)
    dest = Space::Architect::SkillInstaller.dest_root("claude", project: false, env: env).join("architect", "SKILL.md")
    dest.write("# tampered\n")

    assert_raises(Space::Core::Error) do
      Space::Architect::SkillInstaller.install("claude", project: false, force: false, env: env)
    end
  end

  def test_install_overwrites_with_force
    Space::Architect::SkillInstaller.install("claude", project: false, force: false, env: env)
    dest = Space::Architect::SkillInstaller.dest_root("claude", project: false, env: env).join("architect", "SKILL.md")
    dest.write("# tampered\n")

    result = Space::Architect::SkillInstaller.install("claude", project: false, force: true, env: env)
    architect = result[:skills].find { |s| s[:name] == "architect" }
    assert_equal :updated, architect[:action]
    refute_equal "# tampered\n", dest.read
  end

  def test_install_unknown_provider_raises
    assert_raises(Space::Core::Error) do
      Space::Architect::SkillInstaller.install("unknown", project: false, force: false, env: env)
    end
  end

  # dry-run — reports actions without writing

  def test_dry_run_does_not_write_files
    result = Space::Architect::SkillInstaller.install("claude", project: false, force: false,
                                                     env: env, dry_run: true)
    refute result[:dest_root].join("architect").exist?
    refute result[:dest_root].join("architect-research").exist?
  end

  def test_dry_run_reports_would_install_for_new_skills
    result = Space::Architect::SkillInstaller.install("claude", project: false, force: false,
                                                     env: env, dry_run: true)
    assert result[:skills].all? { |s| s[:action] == :would_install }
  end

  def test_dry_run_reports_unchanged_for_existing_same_content
    Space::Architect::SkillInstaller.install("claude", project: false, force: false, env: env)
    result = Space::Architect::SkillInstaller.install("claude", project: false, force: false,
                                                     env: env, dry_run: true)
    assert result[:skills].all? { |s| s[:action] == :unchanged }
  end

  def test_dry_run_reports_conflict_without_force
    Space::Architect::SkillInstaller.install("claude", project: false, force: false, env: env)
    dest = Space::Architect::SkillInstaller.dest_root("claude", project: false, env: env).join("architect", "SKILL.md")
    dest.write("# tampered\n")

    result = Space::Architect::SkillInstaller.install("claude", project: false, force: false,
                                                     env: env, dry_run: true)
    architect = result[:skills].find { |s| s[:name] == "architect" }
    assert_equal :conflict, architect[:action]
  end

  def test_dry_run_reports_would_update_with_force
    Space::Architect::SkillInstaller.install("claude", project: false, force: false, env: env)
    dest = Space::Architect::SkillInstaller.dest_root("claude", project: false, env: env).join("architect", "SKILL.md")
    dest.write("# tampered\n")

    result = Space::Architect::SkillInstaller.install("claude", project: false, force: true,
                                                     env: env, dry_run: true)
    architect = result[:skills].find { |s| s[:name] == "architect" }
    assert_equal :would_update, architect[:action]
    assert_equal "# tampered\n", dest.read
  end
end

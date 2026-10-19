# frozen_string_literal: true

require_relative "test_helper"

# AgentInstaller: renders the five role playbooks through the installed
# architect-loop extension via node, then applies the skill installer's
# write-if-changed / --force semantics. The extension itself is stubbed with
# a minimal importable .ts (same export surface: resolveConfig, renderAgentFile)
# — these tests own the Ruby plumbing, not the extension's rendering, which the
# extension repo tests directly.
class AgentInstallerTest < Space::ArchitectTest
  def setup
    @tmp = temp_env
    @agent_dir = File.join(@tmp[:root], "agent-home")
    @ext_dir = File.join(@tmp[:root], "ext")
    @global_config = File.join(@tmp[:root], "global-architect.yaml")
    FileUtils.mkdir_p([@agent_dir, @ext_dir])
    File.write(File.join(@ext_dir, "architect-loop.ts"), STUB_EXTENSION)
    File.write(@global_config, "version: 1\nroles:\n  coordinator:\n    model: prov/x\n")
  end

  def teardown
    FileUtils.rm_rf(@tmp[:root]) if @tmp
  end

  def env
    @tmp[:env].merge(
      "PI_AGENTS_DIR" => File.join(@agent_dir, "agents"),
      "PI_CODING_AGENT_DIR" => @agent_dir,
      "SPACE_ARCHITECT_GLOBAL_CONFIG" => @global_config
    )
  end

  STUB_EXTENSION = <<~TS
    import * as fs from "node:fs";
    export function resolveConfig(_startDir: string, _options: object): { roles: Record<string, { model: string }> } | null {
      return fs.existsSync(process.env.SPACE_ARCHITECT_GLOBAL_CONFIG || "")
        ? { roles: { coordinator: { model: "prov/x" }, spec: { model: "prov/x" }, builder: { model: "prov/x" },
                     judge: { model: "prov/x" }, narrator: { model: "prov/x" } } }
        : null;
    }
    export function renderAgentFile(role: string, config: { roles: Record<string, { model: string }> }): string {
      return `---\\nname: architect-${role}\\nmodel: ${config.roles[role].model}\\n---\\nplaybook body for ${role}`;
    }
  TS

  def test_install_writes_all_five_playbooks_rendered_by_the_extension
    result = Space::Architect::AgentInstaller.install(env: env, extension_dir: @ext_dir)

    assert_equal Pathname.new(File.join(@agent_dir, "agents")), result[:dest_root]
    assert_equal %w[architect-builder.md architect-coordinator.md architect-judge.md
                    architect-narrator.md architect-spec.md],
                 result[:agents].map { |a| a[:name] }.sort
    assert result[:agents].all? { |a| a[:action] == :installed }

    coordinator = result[:dest_root].join("architect-coordinator.md")
    assert_equal "---\nname: architect-coordinator\nmodel: prov/x\n---\nplaybook body for coordinator\n",
                 File.read(coordinator)
  end

  def test_rerun_is_unchanged_and_tampering_needs_force
    installer = Space::Architect::AgentInstaller
    installer.install(env: env, extension_dir: @ext_dir)
    unchanged = installer.install(env: env, extension_dir: @ext_dir)
    assert unchanged[:agents].all? { |a| a[:action] == :unchanged }

    dest = File.join(@agent_dir, "agents", "architect-spec.md")
    File.write(dest, "# tampered\n")
    error = assert_raises(Space::Core::Error) { installer.install(env: env, extension_dir: @ext_dir) }
    assert_match(/Refusing to overwrite/, error.message)

    forced = installer.install(env: env, extension_dir: @ext_dir, force: true)
    assert_equal :updated, forced[:agents].find { |a| a[:name] == "architect-spec.md" }[:action]
    assert_match(/playbook body for spec/, File.read(dest))
  end

  def test_dry_run_reports_without_writing
    installer = Space::Architect::AgentInstaller
    result = installer.install(env: env, extension_dir: @ext_dir, dry_run: true)
    assert result[:agents].all? { |a| a[:action] == :would_install }
    refute File.exist?(File.join(@agent_dir, "agents", "architect-builder.md"))
  end

  def test_missing_extension_names_the_prerequisite_command
    empty_env = env.merge("PI_CODING_AGENT_DIR" => File.join(@tmp[:root], "nowhere"))
    error = assert_raises(Space::Core::Error) do
      Space::Architect::AgentInstaller.install(env: empty_env, extension_dir: nil)
    end
    assert_match(/architect-loop\.ts not found/, error.message)
    assert_match(/install-extensions/, error.message)
  end

  def test_missing_global_config_surfaces_the_routing_hint
    File.delete(@global_config)
    error = assert_raises(Space::Core::Error) do
      Space::Architect::AgentInstaller.install(env: env, extension_dir: @ext_dir)
    end
    assert_match(/no architect\.yaml found/, error.message)
    assert_match(/routing init --global/, error.message)
  end
end

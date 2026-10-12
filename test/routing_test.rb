# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "tmpdir"

# The v1 architect.yaml contract — the parity matrix from the I02 spec. Every
# row is a named test; the parser must be the pi extension's parity twin.
class RoutingTest < Space::ArchitectTest
  GLOBAL_YAML = <<~YAML
    version: 1
    roles:
      architect:   { model: "prov/architect" }
      spec:        { model: "prov/spec", thinking: low }
      builder:     { model: "prov/global-builder" }
      judge:       { model: "prov/judge" }
      coordinator: { model: "prov/coordinator" }
  YAML

  def routing
    Space::Architect::Routing
  end

  def parse(text, path = "architect.yaml")
    routing.parse(text, path)
  end

  def assert_config_error(text, expected, path = "architect.yaml")
    error = assert_raises(Space::Core::Error) { parse(text, path) }
    assert_match expected, error.message
  end

  def write_global(text)
    path = File.join(@dir, "global-architect.yaml")
    File.write(path, text)
    path
  end

  def setup
    @dir = Dir.mktmpdir("routing-test")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # ── parity matrix ──────────────────────────────────────────────────────────

  # space-local overrides global PER ROLE KEY — builder from the space file,
  # every other role inherited from the global file.
  def test_space_overrides_global_per_role_key
    global = write_global(GLOBAL_YAML)
    File.write(File.join(@dir, "architect.yaml"), <<~YAML)
      version: 1
      roles:
        builder: { model: "prov/space-builder", thinking: high }
    YAML

    with_env("SPACE_ARCHITECT_GLOBAL_CONFIG" => global) do
      merged = routing.for_space(@dir)
      assert_equal({ "model" => "prov/space-builder", "thinking" => "high" }, merged["builder"])
      assert_equal({ "model" => "prov/spec",        "thinking" => "low"  }, merged["spec"])
      assert_equal({ "model" => "prov/judge",       "thinking" => nil    }, merged["judge"])
      assert_equal({ "model" => "prov/coordinator", "thinking" => nil    }, merged["coordinator"])
      assert_equal "prov/architect", merged["architect"]["model"]
    end
  end

  # A trailing :level on model beats the thinking key when both are present.
  def test_model_suffix_beats_thinking_key
    parsed = parse(<<~YAML)
      version: 1
      roles:
        spec:        { model: "prov/spec" }
        builder:     { model: "prov/builder:high", thinking: low }
        judge:       { model: "prov/judge" }
        coordinator: { model: "prov/coordinator" }
    YAML
    assert_equal({ "model" => "prov/builder", "thinking" => "high" }, parsed["builder"])
  end

  # A trailing segment that is NOT a level stays part of the model id (it fails
  # later, loudly, as an unresolvable model id — parse must not eat it).
  def test_non_level_suffix_stays_part_of_model_id
    parsed = parse(<<~YAML)
      version: 1
      roles:
        spec:        { model: "prov/spec" }
        builder:     { model: "prov/builder:floaty", thinking: low }
        judge:       { model: "prov/judge" }
        coordinator: { model: "prov/coordinator" }
    YAML
    assert_equal({ "model" => "prov/builder:floaty", "thinking" => "low" }, parsed["builder"])
  end

  def test_unknown_role_key_fails_loud
    assert_config_error(<<~YAML, /roles\.qa — expected one of architect\|spec\|builder\|judge\|coordinator, got "qa"/)
      version: 1
      roles:
        qa: { model: "prov/qa" }
    YAML
  end

  def test_unknown_entry_key_fails_loud
    assert_config_error(<<~YAML, /roles\.builder\.temperature — expected one of model\|thinking, got "temperature"/)
      version: 1
      roles:
        builder: { model: "prov/builder", temperature: 3 }
    YAML
  end

  def test_missing_or_blank_model_fails_loud
    assert_config_error(<<~YAML, /roles\.builder\.model — expected non-empty 'provider\/model-id\[:level\]', got nil/)
      version: 1
      roles:
        builder: { thinking: low }
    YAML
    assert_config_error(<<~YAML, /roles\.builder\.model.*got ""/)
      version: 1
      roles:
        builder: { model: "" }
    YAML
    assert_config_error(<<~YAML, /roles\.builder\.model.*got "   "/)
      version: 1
      roles:
        builder: { model: "   " }
    YAML
  end

  def test_bad_version_fails_loud
    [2, "1", true, "1.0"].each do |bad|
      assert_config_error(<<~YAML, /version — expected integer 1, got #{Regexp.escape(bad.inspect)}/)
        version: #{bad.inspect}
        roles:
          builder: { model: "prov/builder" }
      YAML
    end
    assert_config_error(<<~YAML, /version — expected integer 1, got nil/)
      roles:
        builder: { model: "prov/builder" }
    YAML
  end

  def test_empty_file_fails_loud
    assert_config_error("", /<top> — expected a YAML mapping, got nil/)
  end

  def test_malformed_yaml_fails_loud_wrapping_parser_message
    assert_config_error("roles: [oops\n", %r{architect\.yaml \(bad\.yaml\): malformed YAML — }, "bad.yaml")
  end

  def test_duplicate_keys_fail_loud
    assert_config_error(<<~YAML, /duplicate mapping key 'builder' — map keys must be unique/)
      version: 1
      roles:
        builder: { model: "prov/one" }
        builder: { model: "prov/two" }
    YAML
    assert_config_error(<<~YAML, /duplicate mapping key 'model'/)
      version: 1
      roles:
        builder: { model: "prov/one", model: "prov/two" }
    YAML
    # anywhere in the document — including mappings nested in sequences (under
    # an ignored top-level key, so nothing else rejects this input)
    assert_config_error(<<~YAML, /duplicate mapping key 'a' — map keys must be unique/)
      notes:
        - {a: 1, a: 2}
      version: 1
      roles:
        builder: { model: "prov/builder" }
    YAML
  end

  def test_aliases_accepted
    parsed = parse(<<~YAML)
      version: 1
      roles:
        spec:        &shared { model: "prov/spec", thinking: low }
        builder:     *shared
        judge:       { model: "prov/judge" }
        coordinator: { model: "prov/coordinator" }
    YAML
    assert_equal({ "model" => "prov/spec", "thinking" => "low" }, parsed["builder"])
    assert_equal({ "model" => "prov/spec", "thinking" => "low" }, parsed["spec"])
  end

  def test_missing_agent_role_after_merge_names_files_joined
    global = write_global(<<~YAML)
      version: 1
      roles:
        builder: { model: "prov/global-builder" }
    YAML
    File.write(File.join(@dir, "architect.yaml"), <<~YAML)
      version: 1
      roles:
        judge: { model: "prov/judge" }
    YAML

    with_env("SPACE_ARCHITECT_GLOBAL_CONFIG" => global) do
      error = assert_raises(Space::Core::Error) { routing.for_space(@dir) }
      assert_match(/#{Regexp.escape(global)} \+ #{Regexp.escape(File.join(@dir, "architect.yaml"))}/, error.message)
      assert_match(/roles\.spec — expected all agent roles spec\|builder\|judge\|coordinator to be routed, got \(missing\)/, error.message)
    end
  end

  def test_no_config_resolves_nil_without_side_effects
    with_env("SPACE_ARCHITECT_GLOBAL_CONFIG" => File.join(@dir, "missing-global.yaml")) do
      assert_nil routing.for_space(@dir)
    end
    assert_equal [], Dir.children(@dir), "no config anywhere must leave no side effects"
  end

  def test_bad_thinking_value_fails_loud_naming_choices
    assert_config_error(<<~YAML, /roles\.builder\.thinking — expected one of off\|minimal\|low\|medium\|high\|xhigh\|max, got "loud"/)
      version: 1
      roles:
        builder: { model: "prov/builder", thinking: loud }
    YAML
    assert_config_error(<<~YAML, /roles\.builder\.thinking.*got 3/)
      version: 1
      roles:
        builder: { model: "prov/builder", thinking: 3 }
    YAML
  end

  def test_every_valid_thinking_level_parses
    Space::Architect::Harness::THINKING_LEVELS.each do |level|
      parsed = parse(<<~YAML)
        version: 1
        roles:
          builder: { model: "prov/builder", thinking: "#{level}" }
      YAML
      assert_equal level, parsed["builder"]["thinking"]
    end
  end

  # psych reads a bare `off` as YAML 1.1 boolean false; the extension's YAML 1.2
  # parser reads it as the string "off" — both sides must accept `thinking: off`.
  def test_bare_off_thinking_parses_as_off
    parsed = parse(<<~YAML)
      version: 1
      roles:
        builder: { model: "prov/builder", thinking: off }
    YAML
    assert_equal "off", parsed["builder"]["thinking"]
  end

  def test_non_string_role_key_fails_loud
    assert_config_error(<<~YAML, /roles\.1 — expected one of architect\|spec\|builder\|judge\|coordinator, got 1/)
      version: 1
      roles:
        1: { model: "prov/builder" }
    YAML
  end

  # Parity with the extension: unknown TOP-LEVEL keys are ignored, not errors.
  def test_unknown_top_level_keys_ignored
    parsed = parse(<<~YAML)
      version: 1
      notes: hello
      roles:
        builder: { model: "prov/builder" }
    YAML
    assert_equal "prov/builder", parsed["builder"]["model"]
  end
end

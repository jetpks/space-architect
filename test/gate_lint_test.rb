# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class GateLintTest < Space::ArchitectTest
  def lint(gates)
    Space::Architect::GateLint.call(gates)
  end

  def create_real_space(dir)
    FileUtils.mkdir_p(File.join(dir, "architecture"))
    FileUtils.mkdir_p(File.join(dir, "repos"))
    FileUtils.mkdir_p(File.join(dir, "tmp"))
    data = {
      "version" => 1, "id" => "test-space", "title" => "Test", "status" => "active",
      "created_at" => "2026-06-19T00:00:00Z", "updated_at" => "2026-06-19T00:00:00Z",
      "repos" => [], "notes" => [], "tickets" => [], "tags" => []
    }
    File.write(File.join(dir, "space.yaml"), YAML.dump(data))
    system("git", "-C", dir, "init", "-q", "-b", "main", exception: false) ||
      system("git", "-C", dir, "init", "-q")
    system("git", "-C", dir, "config", "user.name", "Test Builder")
    system("git", "-C", dir, "config", "user.email", "test@example.com")
    system("git", "-C", dir, "add", "space.yaml")
    system("git", "-C", dir, "commit", "-q", "-m", "init")
    Space::Core::Space.load(dir)
  end

  def well_formed_gate(overrides = {})
    {
      "id" => "suite-green",
      "ac" => "AC1",
      "cmd" => "bundle exec rake test",
      "expect" => { "exit_code" => 0 }
    }.merge(overrides)
  end

  # ── absent / empty is allowed ─────────────────────────────────────────────

  def test_nil_gates_is_success
    result = lint(nil)
    assert result.success?, "nil should be Success (prose-judged only)"
    assert_equal [], result.value!
  end

  def test_empty_array_is_success
    result = lint([])
    assert result.success?, "empty array should be Success"
    assert_equal [], result.value!
  end

  # ── well-formed block parses cleanly ─────────────────────────────────────

  def test_single_well_formed_gate
    gates = [well_formed_gate]
    result = lint(gates)
    assert result.success?, "well-formed gate must succeed: #{result.failure rescue nil}"
  end

  def test_multiple_well_formed_gates_with_unique_ids
    gates = [
      well_formed_gate("id" => "gate-a"),
      well_formed_gate("id" => "gate-b", "ac" => "AC2", "cmd" => "echo ok",
                       "expect" => { "stdout_match" => "ok" })
    ]
    result = lint(gates)
    assert result.success?, "multiple well-formed gates must succeed: #{result.failure rescue nil}"
    assert_equal 2, result.value!.length
  end

  def test_gate_with_all_optional_fields
    gates = [well_formed_gate(
      "cwd" => "repos/my-repo",
      "expect" => {
        "exit_code" => 0,
        "stdout_match" => "ok",
        "threshold" => { "match" => "(\\d+) failures", "op" => "==", "value" => 0 }
      }
    )]
    result = lint(gates)
    assert result.success?, "gate with all optional fields must succeed: #{result.failure rescue nil}"
  end

  def test_gate_with_cwd
    gates = [well_formed_gate("cwd" => "repos/space-architect")]
    result = lint(gates)
    assert result.success?
  end

  # ── required field missing ────────────────────────────────────────────────

  def test_missing_cmd_is_failure
    gates = [well_formed_gate.tap { |g| g.delete("cmd") }]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("cmd") }
  end

  def test_empty_cmd_is_failure
    gates = [well_formed_gate("cmd" => "  ")]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("cmd") }
  end

  def test_missing_id_is_failure
    gates = [well_formed_gate.tap { |g| g.delete("id") }]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("id") }
  end

  def test_empty_id_is_failure
    gates = [well_formed_gate("id" => "")]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("id") }
  end

  def test_missing_ac_is_failure
    gates = [well_formed_gate.tap { |g| g.delete("ac") }]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("ac") }
  end

  def test_missing_expect_is_failure
    gates = [well_formed_gate.tap { |g| g.delete("expect") }]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("expect") }
  end

  # ── duplicate id ──────────────────────────────────────────────────────────

  def test_duplicate_id_is_failure
    gates = [
      well_formed_gate("id" => "dup"),
      well_formed_gate("id" => "dup", "ac" => "AC2", "cmd" => "echo 2")
    ]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("duplicate") && e.include?("dup") }
  end

  # ── unknown keys ─────────────────────────────────────────────────────────

  def test_unknown_gate_key_is_failure
    gates = [well_formed_gate("command" => "echo nope")]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("unknown") && e.include?("command") }
  end

  def test_unknown_expect_key_is_failure
    gates = [well_formed_gate("expect" => { "exit_code" => 0, "expects" => "typo" })]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("unknown") && e.include?("expects") }
  end

  # ── expect must have >=1 known key ───────────────────────────────────────

  def test_empty_expect_hash_is_failure
    gates = [well_formed_gate("expect" => {})]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("expect") && e.include?("at least one") }
  end

  # ── exit_code must be Integer ────────────────────────────────────────────

  def test_exit_code_string_is_failure
    gates = [well_formed_gate("expect" => { "exit_code" => "0" })]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("exit_code") && e.include?("Integer") }
  end

  # ── threshold shape ───────────────────────────────────────────────────────

  def test_threshold_with_valid_op
    %w[>= <= > < == !=].each do |op|
      gates = [well_formed_gate("expect" => {
        "threshold" => { "match" => "(\\d+) failures", "op" => op, "value" => 0 }
      })]
      result = lint(gates)
      assert result.success?, "op '#{op}' must be valid: #{result.failure rescue nil}"
    end
  end

  def test_threshold_bad_op_is_failure
    gates = [well_formed_gate("expect" => {
      "threshold" => { "match" => "(\\d+) failures", "op" => "=~", "value" => 0 }
    })]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("op") }
  end

  def test_threshold_match_zero_captures_is_failure
    gates = [well_formed_gate("expect" => {
      "threshold" => { "match" => "no captures here", "op" => "==", "value" => 0 }
    })]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("capture") }
  end

  def test_threshold_match_two_captures_is_failure
    gates = [well_formed_gate("expect" => {
      "threshold" => { "match" => "(\\d+) (failures)", "op" => "==", "value" => 0 }
    })]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("capture") }
  end

  def test_threshold_match_exactly_one_capture_is_success
    gates = [well_formed_gate("expect" => {
      "threshold" => { "match" => "(\\d+) failures", "op" => "==", "value" => 0 }
    })]
    result = lint(gates)
    assert result.success?, "one capture group must succeed: #{result.failure rescue nil}"
  end

  def test_threshold_unknown_key_is_failure
    gates = [well_formed_gate("expect" => {
      "threshold" => { "match" => "(\\d+) failures", "op" => "==", "value" => 0, "extra" => "bad" }
    })]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("unknown") && e.include?("extra") }
  end

  def test_threshold_value_must_be_numeric
    gates = [well_formed_gate("expect" => {
      "threshold" => { "match" => "(\\d+) failures", "op" => "==", "value" => "0" }
    })]
    result = lint(gates)
    refute result.success?
    assert result.failure.any? { |e| e.include?("value") && e.include?("Number") }
  end

  # ── non-list YAML is failure ──────────────────────────────────────────────

  def test_non_list_yaml_is_failure
    result = lint({ "id" => "oops" })
    refute result.success?
    assert result.failure.any? { |e| e.include?("YAML list") }
  end

  # ── freeze! integration: well-formed block freezes; malformed raises ──────

  def test_freeze_succeeds_with_well_formed_gates_block
    dir = Dir.mktmpdir("gate-lint-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    slice = File.join(dir, "architecture", "I01-my-slice.md")
    text = File.read(slice)
    gate_yaml = <<~YAML
      - id: suite-green
        ac: AC1
        cmd: echo ok
        expect:
          exit_code: 0
    YAML
    text = text.sub(/^```gates\n.*?^```/m, "```gates\n#{gate_yaml}```")
    File.write(slice, text)

    sha = project.freeze!("my-slice")
    assert_match(/\A[0-9a-f]{40}\z/, sha)
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_freeze_succeeds_with_empty_gates_block_and_warns
    dir = Dir.mktmpdir("gate-lint-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    warnings = []
    sha = project.freeze!("my-slice", warnings: warnings)
    assert_match(/\A[0-9a-f]{40}\z/, sha)
    assert_equal 1, warnings.length
    assert_match(/no gates/, warnings[0])
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_freeze_raises_on_malformed_gates_block
    dir = Dir.mktmpdir("gate-lint-test")
    space = create_real_space(dir)

    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("my-slice")

    slice = File.join(dir, "architecture", "I01-my-slice.md")
    text = File.read(slice)
    # missing cmd
    bad_yaml = <<~YAML
      - id: broken
        ac: AC1
        expect:
          exit_code: 0
    YAML
    text = text.sub(/^```gates\n.*?^```/m, "```gates\n#{bad_yaml}```")
    File.write(slice, text)

    err = assert_raises(Space::Core::Error) { project.freeze!("my-slice") }
    assert_match(/ill-formed gates/, err.message)
    assert_match(/cmd/, err.message)
  ensure
    FileUtils.rm_rf(dir)
  end
end

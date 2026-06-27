# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../app/contracts/create_annotation"

class CreateAnnotationContractTest < Minitest::Test
  def contract = Space::Server::Contracts::CreateAnnotation.new

  def test_valid_full_annotation
    r = contract.call(annotation: {
      body: "great point",
      target_kind: "turn",
      anchor_message_id: "42"
    })
    assert r.success?
    assert_equal 42, r.to_h.dig(:annotation, :anchor_message_id)
  end

  def test_valid_minimal_annotation
    r = contract.call(annotation: {body: "note"})
    assert r.success?
  end

  def test_valid_empty_annotation
    r = contract.call(annotation: {})
    assert r.success?
  end

  def test_rejects_missing_outer_key
    r = contract.call({})
    assert r.failure?
    assert_includes r.errors.to_h[:annotation], "is missing"
  end

  def test_rejects_annotation_as_string
    r = contract.call(annotation: "bad")
    assert r.failure?
    assert_includes r.errors.to_h[:annotation], "must be a hash"
  end

  def test_coerces_anchor_message_id_from_string
    r = contract.call(annotation: {anchor_message_id: "123"})
    assert r.success?
    assert_equal 123, r.to_h.dig(:annotation, :anchor_message_id)
  end

  def test_rejects_bad_integer_for_anchor_message_id
    r = contract.call(annotation: {anchor_message_id: "not_a_number"})
    assert r.failure?
    assert r.errors.to_h.dig(:annotation, :anchor_message_id)
  end

  def test_accepts_nil_anchor_message_id
    r = contract.call(annotation: {anchor_message_id: nil})
    assert r.success?
  end

  def test_rejects_selector_as_string
    r = contract.call(annotation: {selector: "bad"})
    assert r.failure?
    assert r.errors.to_h.dig(:annotation, :selector)
  end

  def test_accepts_selector_as_hash
    r = contract.call(annotation: {
      target_kind: "message",
      selector: {exact: "hello world", prefix: "say ", suffix: " goodbye"}
    })
    assert r.success?
  end

  def test_unknown_inner_keys_are_dropped
    r = contract.call(annotation: {body: "note", unknown: "x"})
    assert r.success?
    refute r.to_h.dig(:annotation, :unknown)
  end

  # --- §E: selector_shape rule ---------------------------------------------

  def test_selector_on_non_message_target_fails
    r = contract.call(annotation: {target_kind: "turn", selector: {exact: "hello"}})
    assert r.failure?
    assert_includes r.errors.to_h.dig(:annotation, :selector), "is only valid for message targets"
  end

  def test_selector_on_message_target_missing_exact_fails
    r = contract.call(annotation: {target_kind: "message", selector: {prefix: "before", suffix: "after"}})
    assert r.failure?
    assert_includes r.errors.to_h.dig(:annotation, :selector), "must quote the selected text"
  end

  def test_selector_with_unknown_key_fails
    r = contract.call(annotation: {target_kind: "message", selector: {exact: "hello", unknown_key: "x"}})
    assert r.failure?
    assert_includes r.errors.to_h.dig(:annotation, :selector), "has unknown keys"
  end

  def test_valid_w3c_selector_on_message_target
    r = contract.call(annotation: {
      target_kind: "message",
      selector: {exact: "hello", prefix: "say ", suffix: " world", position: 3}
    })
    assert r.success?
  end

  def test_highlight_without_comment_passes
    r = contract.call(annotation: {target_kind: "message", selector: {exact: "selected text"}})
    assert r.success?
  end

  # --- §E: coherent_target #4 rule -----------------------------------------

  def test_tool_use_id_on_non_tool_target_fails
    r = contract.call(annotation: {target_kind: "turn", tool_use_id: "tool_abc"})
    assert r.failure?
    assert_includes r.errors.to_h.dig(:annotation, :tool_use_id), "is only valid for tool targets"
  end

  def test_tool_target_with_tool_use_id_passes
    r = contract.call(annotation: {target_kind: "tool", tool_use_id: "tool_abc"})
    assert r.success?
  end
end

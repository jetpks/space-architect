# frozen_string_literal: true

require_relative "test_helper"

class GateEvaluatorTest < Space::ArchitectTest
  def ev(stdout:, exit_code:, expect:)
    Space::Architect::GateEvaluator.call(stdout: stdout, exit_code: exit_code, expect: expect)
  end

  # ── exit_code ──────────────────────────────────────────────────────────────

  def test_exit_code_pass
    r = ev(stdout: "", exit_code: 0, expect: { "exit_code" => 0 })
    assert r.pass?
    assert_empty r.reason
  end

  def test_exit_code_fail
    r = ev(stdout: "", exit_code: 1, expect: { "exit_code" => 0 })
    refute r.pass?
    assert_match(/exit_code/, r.reason)
  end

  def test_exit_code_nil_fails
    r = ev(stdout: "", exit_code: nil, expect: { "exit_code" => 0 })
    refute r.pass?
  end

  # ── stdout_match ───────────────────────────────────────────────────────────

  def test_stdout_match_pass
    r = ev(stdout: "811 runs, 0 failures\n", exit_code: 0, expect: { "stdout_match" => "0 failures" })
    assert r.pass?
  end

  def test_stdout_match_fail
    r = ev(stdout: "3 failures\n", exit_code: 0, expect: { "stdout_match" => "0 failures" })
    refute r.pass?
    assert_match(/0 failures/, r.reason)
  end

  # ── threshold — all six ops ────────────────────────────────────────────────

  THRESH_BASE = { "match" => 'score: ([\d.]+)', "value" => 50 }.freeze

  def test_threshold_ge_pass
    r = ev(stdout: "score: 50\n", exit_code: 0, expect: { "threshold" => THRESH_BASE.merge("op" => ">=") })
    assert r.pass?
  end

  def test_threshold_ge_fail
    r = ev(stdout: "score: 49\n", exit_code: 0, expect: { "threshold" => THRESH_BASE.merge("op" => ">=") })
    refute r.pass?
    assert_match(/threshold/, r.reason)
  end

  def test_threshold_le_pass
    r = ev(stdout: "score: 50\n", exit_code: 0, expect: { "threshold" => THRESH_BASE.merge("op" => "<=") })
    assert r.pass?
  end

  def test_threshold_gt_pass
    r = ev(stdout: "score: 51\n", exit_code: 0, expect: { "threshold" => THRESH_BASE.merge("op" => ">") })
    assert r.pass?
  end

  def test_threshold_lt_pass
    r = ev(stdout: "score: 49\n", exit_code: 0, expect: { "threshold" => THRESH_BASE.merge("op" => "<") })
    assert r.pass?
  end

  def test_threshold_eq_pass
    r = ev(stdout: "score: 50\n", exit_code: 0, expect: { "threshold" => THRESH_BASE.merge("op" => "==") })
    assert r.pass?
  end

  def test_threshold_ne_pass
    r = ev(stdout: "score: 99\n", exit_code: 0, expect: { "threshold" => THRESH_BASE.merge("op" => "!=") })
    assert r.pass?
  end

  def test_threshold_ne_fail
    r = ev(stdout: "score: 50\n", exit_code: 0, expect: { "threshold" => THRESH_BASE.merge("op" => "!=") })
    refute r.pass?
  end

  # ── threshold — edge cases ─────────────────────────────────────────────────

  def test_threshold_metric_not_found
    r = ev(stdout: "no metrics\n", exit_code: 0,
           expect: { "threshold" => THRESH_BASE.merge("op" => ">=") })
    refute r.pass?
    assert_match(/metric not found/, r.reason)
  end

  def test_threshold_non_numeric_capture
    r = ev(stdout: "score: abc\n", exit_code: 0,
           expect: { "threshold" => { "match" => 'score: (\w+)', "op" => ">=", "value" => 1 } })
    refute r.pass?
    assert_match(/not numeric/, r.reason)
  end

  def test_threshold_float_capture
    r = ev(stdout: "ratio: 0.95\n", exit_code: 0,
           expect: { "threshold" => { "match" => 'ratio: ([\d.]+)', "op" => ">=", "value" => 0.9 } })
    assert r.pass?
  end

  # ── AND-combination ────────────────────────────────────────────────────────

  def test_and_all_pass
    r = ev(stdout: "ok\n", exit_code: 0, expect: { "exit_code" => 0, "stdout_match" => "ok" })
    assert r.pass?
  end

  def test_and_first_fails_stops_early
    r = ev(stdout: "ok\n", exit_code: 1, expect: { "exit_code" => 0, "stdout_match" => "ok" })
    refute r.pass?
    assert_match(/exit_code/, r.reason)
  end

  def test_and_second_fails
    r = ev(stdout: "wrong\n", exit_code: 0, expect: { "exit_code" => 0, "stdout_match" => "expected" })
    refute r.pass?
    assert_match(/expected/, r.reason)
  end

  # ── symbol keys are tolerated (defensive) ─────────────────────────────────

  def test_symbol_keys_in_expect
    r = ev(stdout: "", exit_code: 0, expect: { exit_code: 0 })
    assert r.pass?
  end

  # ── threshold — last-occurrence matching (Fix A) ───────────────────────────

  def test_threshold_matches_last_occurrence_not_first
    # minitest-style: throughput line appears BEFORE the summary line.
    # "(\d+) runs" first matches "4183" inside "13.4183 runs/s"; the summary
    # line "870 runs" appears later.  The gate must capture 870, not 4183.
    stdout = "Finished in 64.8s, 13.4183 runs/s, 52.0 assertions/s.\n" \
             "870 runs, 3372 assertions, 0 failures, 0 errors, 0 skips\n"
    r = ev(stdout: stdout, exit_code: 0,
           expect: { "threshold" => { "match" => '(\d+) runs', "op" => ">=", "value" => 800 } })
    assert r.pass?, "expected pass capturing 870 from summary line, got: #{r.reason}"
  end

  def test_threshold_single_match_unchanged
    r = ev(stdout: "870 runs, 0 failures\n", exit_code: 0,
           expect: { "threshold" => { "match" => '(\d+) runs', "op" => ">=", "value" => 800 } })
    assert r.pass?
  end
end

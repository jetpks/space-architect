# frozen_string_literal: true

require "test_helper"
require "tempfile"

class ConfigDurationTest < Minitest::Test
  include TestHelpers

  Duration = SpaceArchitect::Pristine::Config::Duration
  Store = SpaceArchitect::Pristine::Config::Store

  # G8 unit tests: each parsing case from the gate threshold.
  # ("6h" → 21600, "90m" → 5400, "45s" → 45, bare integer 21600 → 21600,
  # bare numeric string "21600" → 21600. An invalid duration ("6x",
  # "", "-3h") → Failure with a field-level message.)

  def test_parses_6h_as_21600
    assert_equal 21_600, Duration.parse("6h").success
  end

  def test_parses_90m_as_5400
    assert_equal 5_400, Duration.parse("90m").success
  end

  def test_parses_45s_as_45
    assert_equal 45, Duration.parse("45s").success
  end

  def test_parses_30d_as_30_days
    assert_equal 30 * 86_400, Duration.parse("30d").success
  end

  def test_parses_bare_integer_string_as_seconds
    assert_equal 21_600, Duration.parse("21600").success
  end

  def test_passes_through_integer_input
    assert_equal 21_600, Duration.parse(21_600).success
    assert_equal 1, Duration.parse(1).success
  end

  def test_strips_whitespace
    assert_equal 21_600, Duration.parse("  6h  ").success
  end

  def test_rejects_empty_string_with_failure_message
    result = Duration.parse("")
    assert result.failure?
    assert_includes result.failure, "invalid duration"
    assert_includes result.failure, "\"\""
  end

  def test_rejects_whitespace_only_string
    result = Duration.parse("   ")
    assert result.failure?
    assert_includes result.failure, "invalid duration"
  end

  def test_rejects_invalid_unit_suffix
    result = Duration.parse("6x")
    assert result.failure?
    assert_includes result.failure, "invalid duration"
    assert_includes result.failure, "\"6x\""
  end

  def test_rejects_negative_value
    result = Duration.parse("-3h")
    assert result.failure?
    assert_includes result.failure, "invalid duration"
    assert_includes result.failure, "\"-3h\""
  end

  def test_rejects_negative_integer_input
    result = Duration.parse(-100)
    assert result.failure?
    assert_includes result.failure, "invalid duration"
  end

  def test_rejects_zero_integer_input
    result = Duration.parse(0)
    assert result.failure?
    assert_includes result.failure, "invalid duration"
  end

  def test_rejects_zero_duration_string
    result = Duration.parse("0h")
    assert result.failure?
    assert_includes result.failure, "invalid duration"
  end

  def test_rejects_non_numeric_string
    result = Duration.parse("abc")
    assert result.failure?
    assert_includes result.failure, "invalid duration"
  end

  def test_rejects_nil_input
    result = Duration.parse(nil)
    assert result.failure?
    assert_includes result.failure, "invalid duration"
  end

  def test_rejects_float_input
    # The Config schema is Integer; floats are not a valid input.
    # The parser treats them as the unknown-type case and returns
    # Failure — the caller (Config::Store.load) is responsible
    # for not passing floats in the first place.
    result = Duration.parse(1.5)
    assert result.failure?
    assert_includes result.failure, "invalid duration"
  end

  # ---- G8 integration: the load-layer normalization actually
  # runs BEFORE the contract (which still validates :integer, gt?: 0).

  def test_store_load_normalizes_6h_to_21600
    Tempfile.create(["config-cf1", ".yaml"]) do |f|
      f.write(<<~YAML)
        base_dir: /tmp/cf1
        refresh_interval: 6h
        concurrency: 4
        repos: []
        orgs: []
      YAML
      f.flush

      cfg = Store.load(f.path).success
      assert_equal 21_600, cfg.refresh_interval,
        "human-duration '6h' must normalize to 21600 in the loaded Config"
    end
  end

  def test_store_load_normalizes_90m_to_5400
    Tempfile.create(["config-cf1", ".yaml"]) do |f|
      f.write("refresh_interval: 90m\n")
      f.flush
      cfg = Store.load(f.path).success
      assert_equal 5_400, cfg.refresh_interval
    end
  end

  def test_store_load_accepts_bare_integer_string
    Tempfile.create(["config-cf1", ".yaml"]) do |f|
      f.write("refresh_interval: '21600'\n")
      f.flush
      cfg = Store.load(f.path).success
      assert_equal 21_600, cfg.refresh_interval
    end
  end

  def test_store_load_returns_failure_for_invalid_duration
    Tempfile.create(["config-cf1", ".yaml"]) do |f|
      f.write("refresh_interval: 6x\n")
      f.flush
      result = Store.load(f.path)
      assert result.failure?
      # The Failure is the duration parser's message — not a
      # contract-layer integer-typed rejection.
      assert_includes result.failure, "invalid duration"
    end
  end

  def test_store_load_returns_failure_for_negative_duration
    Tempfile.create(["config-cf1", ".yaml"]) do |f|
      f.write("refresh_interval: -3h\n")
      f.flush
      result = Store.load(f.path)
      assert result.failure?
      assert_includes result.failure, "invalid duration"
    end
  end

  def test_store_load_returns_failure_for_empty_duration
    Tempfile.create(["config-cf1", ".yaml"]) do |f|
      f.write("refresh_interval: ''\n")
      f.flush
      result = Store.load(f.path)
      assert result.failure?
      assert_includes result.failure, "invalid duration"
    end
  end
end

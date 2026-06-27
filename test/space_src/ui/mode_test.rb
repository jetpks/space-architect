# frozen_string_literal: true

require "space_src/test_helper"
require "stringio"

class ModeTest < Minitest::Test
  Mode = Space::Src::UI::Mode

  TtyIO = Struct.new(:tty_value) do
    def tty? = tty_value
  end

  def tty = TtyIO.new(true)
  def non_tty = TtyIO.new(false)

  def resolve(flags: {}, env: {}, out: tty)
    Mode.resolve(flags: flags, env: env, out: out)
  end

  # ---------------------------------------------------------------------------
  # format
  # ---------------------------------------------------------------------------

  def test_json_flag_produces_json_format
    assert_equal :json, resolve(flags: {json: true}).format
  end

  def test_plain_flag_produces_plain_format
    assert_equal :plain, resolve(flags: {plain: true}).format
  end

  def test_non_tty_no_flag_produces_plain_format
    assert_equal :plain, resolve(out: non_tty).format
  end

  def test_tty_no_flags_produces_pretty_format
    assert_equal :pretty, resolve(flags: {}, env: {}, out: tty).format
  end

  def test_json_wins_over_plain_when_both_set
    assert_equal :json, resolve(flags: {json: true, plain: true}).format
  end

  # ---------------------------------------------------------------------------
  # color
  # ---------------------------------------------------------------------------

  def test_color_true_on_tty_pretty_no_disablers
    assert resolve(flags: {}, env: {}, out: tty).color,
      "expected color: true on TTY :pretty with no disablers"
  end

  def test_no_color_flag_disables_color
    refute resolve(flags: {no_color: true}, env: {}, out: tty).color,
      "expected color: false with --no-color"
  end

  def test_no_color_env_present_nonempty_disables_color
    refute resolve(flags: {}, env: {"NO_COLOR" => "1"}, out: tty).color
  end

  def test_no_color_env_empty_does_not_disable_color
    assert resolve(flags: {}, env: {"NO_COLOR" => ""}, out: tty).color,
      "NO_COLOR='' (empty) must NOT disable color"
  end

  def test_term_dumb_disables_color
    refute resolve(flags: {}, env: {"TERM" => "dumb"}, out: tty).color
  end

  def test_non_tty_disables_color
    refute resolve(flags: {}, env: {}, out: non_tty).color
  end

  def test_plain_format_disables_color
    refute resolve(flags: {plain: true}, env: {}, out: tty).color
  end

  def test_json_format_disables_color
    refute resolve(flags: {json: true}, env: {}, out: tty).color
  end

  def test_clicolor_force_enables_color_on_non_tty
    assert resolve(flags: {}, env: {"CLICOLOR_FORCE" => "1"}, out: non_tty).color,
      "CLICOLOR_FORCE=1 must force color: true even on non-TTY"
  end

  def test_no_color_flag_beats_clicolor_force
    refute resolve(flags: {no_color: true}, env: {"CLICOLOR_FORCE" => "1"}, out: tty).color,
      "--no-color (flag) must beat CLICOLOR_FORCE (env-force)"
  end

  # ---------------------------------------------------------------------------
  # animate
  # ---------------------------------------------------------------------------

  def test_animate_true_on_pretty_tty_not_quiet_not_ci
    assert resolve(flags: {}, env: {}, out: tty).animate,
      "expected animate: true on :pretty TTY, not-quiet, CI unset"
  end

  def test_animate_false_on_plain_format
    refute resolve(flags: {plain: true}, env: {}, out: tty).animate
  end

  def test_animate_false_on_non_tty
    refute resolve(flags: {}, env: {}, out: non_tty).animate
  end

  def test_animate_false_when_quiet
    refute resolve(flags: {quiet: true}, env: {}, out: tty).animate
  end

  def test_animate_false_when_ci_set
    refute resolve(flags: {}, env: {"CI" => "true"}, out: tty).animate
  end

  def test_animate_false_when_json_format
    refute resolve(flags: {json: true}, env: {}, out: tty).animate
  end

  # ---------------------------------------------------------------------------
  # quiet
  # ---------------------------------------------------------------------------

  def test_quiet_flag_sets_quiet
    assert resolve(flags: {quiet: true}).quiet
  end

  def test_quiet_false_by_default
    refute resolve.quiet
  end

  # ---------------------------------------------------------------------------
  # immutability
  # ---------------------------------------------------------------------------

  def test_mode_is_immutable
    mode = resolve
    assert_raises(NoMethodError) { mode.color = false }
  end
end

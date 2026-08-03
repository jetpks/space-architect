# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "shellwords"

class BugReportTest < Space::ArchitectTest
  def setup
    @tmp = Dir.mktmpdir("bug-report-test")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # ── BugReport.generate without a space ─────────────────────────────────────

  def test_generate_outside_space_writes_to_cwd
    now = Time.new(2026, 7, 1, 12, 0, 0)
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: now)

    expected_path = File.join(@tmp, "architect-bug-report-20260701-120000.md")
    assert_equal Pathname.new(expected_path), result[:body_path]
    assert_path_exists expected_path
  end

  def test_generate_outside_space_body_contains_diagnostics
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: Time.now)

    assert_match(/## Diagnostics/, result[:body])
    assert_match(/space-architect: #{Space::Core::VERSION}/, result[:body])
    assert_match(/ruby: #{RUBY_VERSION}/, result[:body])
  end

  def test_generate_outside_space_body_has_no_space_section
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: Time.now)

    refute_match(/## Space context/, result[:body])
  end

  def test_generate_outside_space_command_targets_repo
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: Time.now)

    assert_match(/gh issue create -R jetpks\/space-architect/, result[:command])
    assert_match(/--body-file/, result[:command])
  end

  def test_generate_outside_space_body_has_template_sections
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: Time.now)

    assert_match(/\*\*Kind:\*\*/, result[:body])
    assert_match(/## Summary/, result[:body])
    assert_match(/## What happened/, result[:body])
    assert_match(/## What was expected/, result[:body])
    assert_match(/## Repro steps/, result[:body])
  end

  # ── BugReport.generate with a space ────────────────────────────────────────

  def test_generate_inside_space_writes_to_space_build_dir
    space = build_fake_space
    now = Time.new(2026, 7, 1, 9, 30, 0)
    result = Space::Architect::BugReport.generate(space: space, cwd: @tmp, now: now)

    expected = space.path.join("build", "bug-report", "architect-bug-report-20260701-093000.md")
    assert_equal expected, result[:body_path]
    assert_path_exists result[:body_path]
  end

  def test_generate_inside_space_body_contains_space_context
    space = build_fake_space(
      id: "20260701-myspace",
      title: "My Space",
      iterations: [
        { "ordinal" => 1, "name" => "first-iter", "verdict" => "COMPLETE" },
        { "ordinal" => 2, "name" => "second-iter" }
      ]
    )
    result = Space::Architect::BugReport.generate(space: space, cwd: @tmp, now: Time.now)

    assert_match(/## Space context/, result[:body])
    assert_match(/Space id: 20260701-myspace/, result[:body])
    assert_match(/Space title: My Space/, result[:body])
    assert_match(/I01 first-iter — COMPLETE/, result[:body])
    assert_match(/I02 second-iter — —/, result[:body])
  end

  def test_generate_inside_space_body_contains_diagnostics
    space = build_fake_space
    result = Space::Architect::BugReport.generate(space: space, cwd: @tmp, now: Time.now)

    assert_match(/## Diagnostics/, result[:body])
    assert_match(/space-architect: #{Space::Core::VERSION}/, result[:body])
    assert_match(/ruby: #{RUBY_VERSION}/, result[:body])
  end

  def test_generate_inside_space_with_no_iterations
    space = build_fake_space(iterations: [])
    result = Space::Architect::BugReport.generate(space: space, cwd: @tmp, now: Time.now)

    assert_match(/## Space context/, result[:body])
    assert_match(/\(none\)/, result[:body])
  end

  # ── Timestamped uniqueness ──────────────────────────────────────────────────

  def test_different_clocks_produce_distinct_body_paths
    t1 = Time.new(2026, 7, 1, 10, 0, 0)
    t2 = Time.new(2026, 7, 1, 10, 0, 1)
    r1 = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: t1)
    r2 = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: t2)

    refute_equal r1[:body_path], r2[:body_path]
    assert_path_exists r1[:body_path]
    assert_path_exists r2[:body_path]
  end

  # ── Path contraction in command string ──────────────────────────────────────

  def test_command_contracts_home_in_body_file_path
    env = { "HOME" => @tmp }
    now = Time.new(2026, 7, 1, 8, 0, 0)
    space = build_fake_space
    # Move the space under @tmp so body_path is under $HOME
    space_in_home = Space::Core::Space.new(
      Pathname.new(@tmp).join("myspace"),
      space.data
    )
    FileUtils.mkdir_p(space_in_home.path.join("build"))
    result = Space::Architect::BugReport.generate(space: space_in_home, cwd: @tmp, env: env, now: now)

    assert_match(/--body-file ~\//, result[:command])
    refute_match(/--body-file #{Regexp.escape(@tmp)}/, result[:command])
  end

  # AC4: bug-report command is wrapped with " \" at flag boundaries
  def test_generate_command_is_wrapped
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: Time.now)

    lines = result[:command].split("\n")
    assert lines.size > 1, "command must be wrapped to multiple lines"
    lines[0..-2].each { |l| assert_match(/ \\$/, l, "all but last line must end with continuation") }
    refute_match(/ \\$/, lines.last)
  end

  def test_command_unquoted_body_file_arg
    env = { "HOME" => @tmp }
    now = Time.new(2026, 7, 1, 8, 0, 0)
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, env: env, now: now)

    # Unquoted means no surrounding quotes around the ~ path
    refute_match(/--body-file "~/, result[:command])
    assert_match(/--body-file ~/, result[:command])
  end

  # ── Title ───────────────────────────────────────────────────────────────────

  def test_title_flows_into_command_and_body_h1
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: Time.now, title: "Widget breaks on save")

    assert_match(/--title "Widget breaks on save"/, result[:command])
    refute_match(/<one-line summary>/, result[:command])
    assert_equal "# Widget breaks on save", result[:body].lines.first.strip
  end

  def test_no_inert_title_comment_anywhere
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: Time.now, title: "Anything")

    refute_match(/<!-- Title:/, result[:body])
  end

  def test_no_title_generates_successfully_without_title_flag_or_h1
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: Time.now)

    refute_match(/--title/, result[:command])
    refute_match(/^# /, result[:body])
  end

  def test_blank_title_treated_as_absent
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: Time.now, title: "")

    refute_match(/--title/, result[:command])
    refute_match(/^# /, result[:body])
  end

  def test_whitespace_only_title_treated_as_absent
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: Time.now, title: "   ")

    refute_match(/--title/, result[:command])
    refute_match(/^# /, result[:body])
  end

  def test_title_with_shell_metacharacters_round_trips_as_one_argument
    title = %q{Weird $HOME "quoted" `tick` it}
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp, now: Time.now, title: title)

    flat = result[:command].gsub(/ \\\n\s*/, " ")
    parsed = Shellwords.split(flat)
    i = parsed.index("--title")
    refute_nil i, "expected --title in command"
    assert_equal title, parsed[i + 1]
  end

  def test_cli_no_title_prints_full_command_without_title_flag
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      Dir.chdir(@tmp) do
        out, _err = invoke("bug-report")

        lines = out.lines
        start = lines.index { |l| l.include?("gh issue create") }
        refute_nil start, "expected the gh issue create command to be printed"
        command_block = lines[start..].take_while { |l| !l.strip.empty? }.join

        assert_match(/gh issue create -R jetpks\/space-architect/, command_block)
        refute_match(/--title/, command_block)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_cli_no_title_nudge_names_rerun_form
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      Dir.chdir(@tmp) do
        out, _err = invoke("bug-report")

        assert_match(/architect bug-report --title/, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_cli_title_option_threads_through_to_command
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      Dir.chdir(@tmp) do
        out, err = invoke("bug-report", "--title", "From the CLI")

        assert_empty err
        assert_match(/--title "From the CLI"/, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ── CLI command ─────────────────────────────────────────────────────────────

  def test_cli_bug_report_exits_0_outside_space
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      Dir.chdir(@tmp) do
        out, err = invoke("bug-report")

        assert_empty err
        assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
        assert_match(/gh issue create -R jetpks\/space-architect/, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_cli_bug_report_prints_diagnostics_to_stdout
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      Dir.chdir(@tmp) do
        out, _err = invoke("bug-report")

        assert_match(/space-architect #{Space::Core::VERSION}/, out)
        assert_match(/ruby #{RUBY_VERSION}/, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  private

  def build_fake_space(id: "20260701-test", title: "Test Space", iterations: [])
    space_dir = Pathname.new(@tmp).join("spaces", id)
    FileUtils.mkdir_p(space_dir.join("build"))

    data = {
      "version" => 1, "id" => id, "title" => title, "status" => "active",
      "created_at" => "2026-07-01T00:00:00Z", "updated_at" => "2026-07-01T00:00:00Z",
      "repos" => [], "notes" => [], "tickets" => [], "tags" => [],
      "project" => { "status" => "active", "iterations" => iterations }
    }
    Space::Core::Space.new(space_dir, data)
  end
end

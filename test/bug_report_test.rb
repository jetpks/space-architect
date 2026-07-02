# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class BugReportTest < Space::ArchitectTest
  def setup
    @tmp = Dir.mktmpdir("bug-report-test")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # ── BugReport.generate without a space ─────────────────────────────────────

  def test_generate_outside_space_writes_to_cwd
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp)

    expected_path = File.join(@tmp, "architect-bug-report.md")
    assert_equal Pathname.new(expected_path), result[:body_path]
    assert_path_exists expected_path
  end

  def test_generate_outside_space_body_contains_diagnostics
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp)

    assert_match(/## Diagnostics/, result[:body])
    assert_match(/space-architect: #{Space::Core::VERSION}/, result[:body])
    assert_match(/ruby: #{RUBY_VERSION}/, result[:body])
  end

  def test_generate_outside_space_body_has_no_space_section
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp)

    refute_match(/## Space context/, result[:body])
  end

  def test_generate_outside_space_command_targets_repo
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp)

    assert_match(/gh issue create -R jetpks\/space-architect/, result[:command])
    assert_match(/--body-file/, result[:command])
  end

  def test_generate_outside_space_body_has_template_sections
    result = Space::Architect::BugReport.generate(space: nil, cwd: @tmp)

    assert_match(/\*\*Kind:\*\*/, result[:body])
    assert_match(/## Summary/, result[:body])
    assert_match(/## What happened/, result[:body])
    assert_match(/## What was expected/, result[:body])
    assert_match(/## Repro steps/, result[:body])
  end

  # ── BugReport.generate with a space ────────────────────────────────────────

  def test_generate_inside_space_writes_to_space_build_dir
    space = build_fake_space
    result = Space::Architect::BugReport.generate(space: space, cwd: @tmp)

    expected = space.path.join("build", "bug-report", "body.md")
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
    result = Space::Architect::BugReport.generate(space: space, cwd: @tmp)

    assert_match(/## Space context/, result[:body])
    assert_match(/Space id: 20260701-myspace/, result[:body])
    assert_match(/Space title: My Space/, result[:body])
    assert_match(/I01 first-iter — COMPLETE/, result[:body])
    assert_match(/I02 second-iter — —/, result[:body])
  end

  def test_generate_inside_space_body_contains_diagnostics
    space = build_fake_space
    result = Space::Architect::BugReport.generate(space: space, cwd: @tmp)

    assert_match(/## Diagnostics/, result[:body])
    assert_match(/space-architect: #{Space::Core::VERSION}/, result[:body])
    assert_match(/ruby: #{RUBY_VERSION}/, result[:body])
  end

  def test_generate_inside_space_with_no_iterations
    space = build_fake_space(iterations: [])
    result = Space::Architect::BugReport.generate(space: space, cwd: @tmp)

    assert_match(/## Space context/, result[:body])
    assert_match(/\(none\)/, result[:body])
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

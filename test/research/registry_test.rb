# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "yaml"

class RegistryTest < Space::ArchitectTest
  def make_run(id, dir)
    Space::Architect::Research::Run.new(
      id:            id,
      topic:         "topic-#{id}",
      pid:           12345,
      dir:           Pathname.new(dir),
      prompt_path:   Pathname.new(dir).join("prompt.md"),
      run_log_path:  Pathname.new(dir).join("run.jsonl"),
      report_path:   Pathname.new(dir).join("report.md"),
      model:         "claude-sonnet-4-6",
      dispatched_at: Time.new(2026, 6, 27, 0, 0, 0, "+00:00")
    )
  end

  def registry(dir)
    Space::Architect::Research::Registry.new(File.join(dir, "r.yaml"))
  end

  def test_add_and_all_round_trip
    Dir.mktmpdir do |d|
      reg = registry(d)
      run = make_run("01-x", d)
      reg.add(run)
      assert_equal 1, reg.all.size
      assert_equal "01-x", reg.all.first.id
    end
  end

  def test_find_returns_run_by_id
    Dir.mktmpdir do |d|
      reg = registry(d)
      run = make_run("01-x", d)
      reg.add(run)
      found = reg.find("01-x")
      assert found, "find must return the run"
      assert_equal "01-x", found.id
    end
  end

  def test_find_returns_nil_for_absent_id
    Dir.mktmpdir do |d|
      reg = registry(d)
      assert_nil reg.find("nope")
    end
  end

  def test_add_dedup_replaces_on_same_id
    Dir.mktmpdir do |d|
      reg = registry(d)
      run = make_run("01-x", d)
      reg.add(run)
      reg.add(run)
      assert_equal 1, reg.all.size, "re-add same id must not duplicate"
    end
  end

  def test_persisted_yaml_uses_string_keys
    Dir.mktmpdir do |d|
      reg = registry(d)
      reg.add(make_run("01-x", d))
      raw = YAML.safe_load(File.read(File.join(d, "r.yaml")), aliases: false)
      assert_equal "01-x", raw.first["id"], "YAML must store string-keyed id"
    end
  end
end

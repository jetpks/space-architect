# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"

# GH #83: `architect research dispatch` bound its `prompts` argument as a
# scalar, so dry-cli's positional-arg matcher only ever saw the first path —
# Supervisor#dispatch already fans out an array correctly, so this must be
# exercised at the CLI layer where the drop actually happens.
class CLIDispatchTest < Space::ArchitectTest
  STUB_BIN = File.expand_path("stub_claude", __dir__)

  def setup_space(root)
    space_dir = File.join(root, "space")
    FileUtils.mkdir_p(space_dir)
    data = {
      "id" => "test", "title" => "T", "status" => "active",
      "repos" => [], "notes" => [], "tickets" => [], "tags" => []
    }
    File.write(File.join(space_dir, "space.yaml"), YAML.dump(data))
    system("git", "-C", space_dir, "init", "-q")
    system("git", "-C", space_dir, "config", "user.email", "t@t")
    system("git", "-C", space_dir, "config", "user.name", "t")
    system("git", "-C", space_dir, "add", "space.yaml")
    system("git", "-C", space_dir, "commit", "-q", "-m", "init")
    space_dir
  end

  def write_prompt(space_dir, name)
    path = File.join(space_dir, "#{name}.prompt.md")
    File.write(path, "Research question about #{name}")
    path
  end

  def test_dispatch_fans_out_every_prompt_given
    root = Dir.mktmpdir("cli-dispatch-test")
    space_dir = setup_space(root)
    p1 = write_prompt(space_dir, "01-a")
    p2 = write_prompt(space_dir, "02-b")
    p3 = write_prompt(space_dir, "03-c")

    Dir.chdir(space_dir) do
      with_env("ARCHITECT_CLAUDE_BIN" => STUB_BIN) do
        out, err = invoke("research", "dispatch", p1, p2, p3)

        assert_empty err
        %w[01-a 02-b 03-c].each do |id|
          assert_match(/dispatched #{id} \(pid \d+\)/, out)
          assert File.exist?(File.join(space_dir, "build", "research", id, "prompt.md")),
            "#{id} must get its own build/research/#{id}/ directory"
          assert File.exist?(File.join(space_dir, "build", "research", id, "run.jsonl"))
        end

        registry = YAML.safe_load(
          File.read(File.join(space_dir, "build", "research", "registry.yaml")), aliases: false
        )
        assert_equal %w[01-a 02-b 03-c], registry.map { |r| r["id"] }.sort
      end
    end
  ensure
    sleep 0.1
    FileUtils.rm_rf(root)
  end

  def test_dispatch_all_prompts_are_visible_to_status
    root = Dir.mktmpdir("cli-dispatch-test")
    space_dir = setup_space(root)
    p1 = write_prompt(space_dir, "01-a")
    p2 = write_prompt(space_dir, "02-b")

    Dir.chdir(space_dir) do
      with_env("ARCHITECT_CLAUDE_BIN" => STUB_BIN) do
        invoke("research", "dispatch", p1, p2)
        out, err = invoke("research", "status")

        assert_empty err
        assert_match(/01-a/, out)
        assert_match(/02-b/, out)
      end
    end
  ensure
    sleep 0.1
    FileUtils.rm_rf(root)
  end

  def test_dispatch_single_prompt_still_works
    root = Dir.mktmpdir("cli-dispatch-test")
    space_dir = setup_space(root)
    p1 = write_prompt(space_dir, "01-solo")

    Dir.chdir(space_dir) do
      with_env("ARCHITECT_CLAUDE_BIN" => STUB_BIN) do
        out, err = invoke("research", "dispatch", p1)

        assert_empty err
        assert_match(/dispatched 01-solo \(pid \d+\)/, out)
        assert File.exist?(File.join(space_dir, "build", "research", "01-solo", "prompt.md"))
      end
    end
  ensure
    sleep 0.1
    FileUtils.rm_rf(root)
  end
end

# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class SessionSyncCursorTest < Space::ArchitectTest
  Cursor = Space::Architect::SessionSync::Cursor

  # (a) load on a missing file returns an empty cursor.
  def test_load_missing_file_returns_empty
    Dir.mktmpdir("cursor-test") do |dir|
      assert_equal({}, Cursor.load(File.join(dir, "nope.yaml")))
    end
  end

  # (b) write then load round-trips size/mtime per path.
  def test_write_then_load_round_trips_entries
    Dir.mktmpdir("cursor-test") do |dir|
      path = File.join(dir, "state.yaml")
      entries = {
        "/a/b.jsonl" => Cursor::Entry.new(size: 42, mtime: 1_753_000_000)
      }
      Cursor.write(path, entries)

      loaded = Cursor.load(path)
      assert_equal 42,          loaded["/a/b.jsonl"].size
      assert_equal 1_753_000_000, loaded["/a/b.jsonl"].mtime
    end
  end

  # (c) write creates parent directories.
  def test_write_creates_parent_directories
    Dir.mktmpdir("cursor-test") do |dir|
      path = File.join(dir, "nested", "deeper", "state.yaml")
      Cursor.write(path, {"/x.jsonl" => Cursor::Entry.new(size: 1, mtime: 1)})
      assert File.exist?(path)
    end
  end

  # (d) write does not leave a .tmp.<pid> sidecar behind.
  def test_write_cleans_up_tmp_file
    Dir.mktmpdir("cursor-test") do |dir|
      path = File.join(dir, "state.yaml")
      Cursor.write(path, {"/x.jsonl" => Cursor::Entry.new(size: 1, mtime: 1)})
      assert_equal ["state.yaml"], Dir.children(dir)
    end
  end
end

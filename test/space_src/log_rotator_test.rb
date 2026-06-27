# frozen_string_literal: true

require "space_src/test_helper"
require "tmpdir"
require "fileutils"
require "time"

class LogRotatorTest < Minitest::Test
  include TestHelpers

  LogRotator = Space::Src::LogRotator

  # Use a fixed "now" so the archive filename is deterministic.
  FIXED_NOW = Time.utc(2026, 6, 13, 10, 15, 30)
  FIXED_TS = "20260613T101530Z"

  def with_log_dir
    Dir.mktmpdir("repo-tender-logrot-") do |dir|
      yield dir
    end
  end

  # ---- G5: oversize log rotates; bytes preserved ----

  def test_oversize_log_rotates_to_timestamped_archive
    with_log_dir do |dir|
      log = File.join(dir, "sync.out.log")
      bytes = "x" * 1024
      File.binwrite(log, bytes)

      result = LogRotator.call(log, threshold_bytes: 100, now: FIXED_NOW)
      assert result.success?
      v = result.success
      assert_equal true, v[:rotated]
      assert_equal "#{log}.#{FIXED_TS}", v[:archive_path]

      # Archive holds the original bytes.
      assert File.exist?(v[:archive_path])
      assert_equal bytes, File.binread(v[:archive_path])

      # Original log path is freed (a new file can be created
      # at the original path on launchd's next spawn).
      refute File.exist?(log)
    end
  end

  def test_under_threshold_log_is_left_byte_for_byte_untouched
    with_log_dir do |dir|
      log = File.join(dir, "sync.out.log")
      bytes = "small content"
      File.binwrite(log, bytes)
      original_mtime = File.mtime(log)
      original_bytes = File.binread(log)

      result = LogRotator.call(log, threshold_bytes: 1024, now: FIXED_NOW)
      assert result.success?
      v = result.success
      assert_equal false, v[:rotated]
      assert_equal "under_threshold", v[:reason]

      # File is unchanged.
      assert File.exist?(log)
      assert_equal original_bytes, File.binread(log)
      assert_equal original_mtime, File.mtime(log)

      # No archive was created.
      assert_nil Dir.children(dir).find { |c| c.start_with?("sync.out.log.") }
    end
  end

  def test_missing_log_is_a_safe_no_op
    with_log_dir do |dir|
      log = File.join(dir, "does-not-exist.log")
      result = LogRotator.call(log, threshold_bytes: 100, now: FIXED_NOW)
      assert result.success?
      v = result.success
      assert_equal false, v[:rotated]
      assert_equal "missing", v[:reason]
    end
  end

  def test_two_rotations_under_different_timestamps_preserve_independent_bytes
    with_log_dir do |dir|
      log = File.join(dir, "sync.out.log")
      bytes1 = "first run bytes"
      bytes2 = "second run bytes"

      File.binwrite(log, bytes1)
      r1 = LogRotator.call(log, threshold_bytes: 5, now: FIXED_NOW)
      assert r1.success?
      assert_equal true, r1.success[:rotated]
      archive1 = r1.success[:archive_path]
      assert_equal bytes1, File.binread(archive1)

      # A new run writes fresh bytes; the rotator picks them up
      # on the next call with a later timestamp.
      File.binwrite(log, bytes2)
      later = FIXED_NOW + 60
      r2 = LogRotator.call(log, threshold_bytes: 5, now: later)
      assert r2.success?
      archive2 = r2.success[:archive_path]
      refute_equal archive1, archive2
      assert_equal bytes2, File.binread(archive2)
    end
  end
end

# frozen_string_literal: true

require "fileutils"
require "time"
require "dry/monads"

module RepoTender
  # Rotates a log file when it exceeds a byte threshold. The
  # archive's filename embeds an ISO-8601-compact timestamp
  # (`YYYYMMDDTHHMMSSZ`) of the rotation event (the injected
  # `now` — deterministic in tests, real `Time.now` in
  # production). The rename is byte-for-byte — no copy, no
  # data loss.
  #
  # The sync process calls this at the top of `Run#call` to
  # rotate the two plist log paths (`<label>.out.log` and
  # `<label>.err.log`). launchd opens those files fresh on the
  # next spawn; the current process's inherited fd still points
  # to the renamed file (writes succeed; the file is the
  # archive). After the process exits, launchd re-opens a new
  # file at the original path. This is the mechanism the spec
  # asked for (gate G5).
  class LogRotator
    extend Dry::Monads[:result]

    # @param log_path [String]           absolute path to the log file to potentially rotate
    # @param threshold_bytes [Integer]   rotation threshold; > this many bytes ⇒ rotate
    # @param now [Time]                  the timestamp to embed in the archive filename
    # @return [Dry::Monads::Result<Hash>] Success({rotated: bool, archive_path: String|nil})
    def self.call(log_path, threshold_bytes:, now: Time.now)
      return Success({rotated: false, archive_path: nil, reason: "missing"}) unless File.exist?(log_path)
      return Success({rotated: false, archive_path: nil, reason: "under_threshold"}) if File.size(log_path) <= threshold_bytes

      archive = build_archive_path(log_path, now)
      FileUtils.mv(log_path, archive)
      Success({rotated: true, archive_path: archive, reason: "oversized"})
    rescue => e
      Failure({log_path: log_path, error: e.class.name, message: e.message})
    end

    def self.build_archive_path(log_path, now)
      ts = now.utc.strftime("%Y%m%dT%H%M%SZ")
      "#{log_path}.#{ts}"
    end
  end
end

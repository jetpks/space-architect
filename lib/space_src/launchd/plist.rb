# frozen_string_literal: true

module Space::Src
  module Launchd
    # Hand-rolled launchd plist emitter. The slice forbids a plist
    # gem (PRD §2, AGENTS.md) — this class emits an XML property
    # list as a string and is validated offline with `plutil -lint`.
    #
    # The plist produced here is a fixed-shape StartInterval-driven
    # agent that:
    #   * runs `src sync` non-interactively under the
    #     repo's mise-managed Ruby (so the right toolchain is in
    #     effect without `mise activate`, which is broken
    #     non-interactively);
    #   * is classified as a Background process (lower scheduling
    #     + I/O priority — sync is a periodic background job);
    #   * writes its stdout/stderr to absolute log files under
    #     the log dir (launchd owns the redirect, the sync process
    #     rotates its own log on each run — see LogRotator);
    #   * has NO `KeepAlive` key — it is a periodic, not a daemon.
    #
    # The caller is responsible for passing absolute paths. We do
    # NOT `File.expand_path` here — that would mask the caller's
    # responsibility to pass absolute paths (the G1 / G3 gates
    # assert that no `~` or `$HOME` appears in any value).
    class Plist
      # The plist's outer XML decl + DOCTYPE — required by
      # plutil's lint and by launchd's parser.
      HEADER = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
      XML
      FOOTER = "</dict>\n</plist>\n"

      class << self
        # Emit a launchd plist for a sync job.
        #
        # @param label [String]              The job label (must be a valid reverse-DNS string; appears as the basename of the on-disk plist).
        # @param refresh_interval [Integer] StartInterval in seconds (must be > 0).
        # @param log_dir [String]            Absolute directory for the standard-out / standard-err logs.
        # @param repo_root [String]          Absolute path to set as WorkingDirectory (so mise finds the repo's mise.toml).
        # @param mise_toml [String]          Absolute path to mise.toml (pinned via EnvironmentVariables.MISE_CONFIG_FILE).
        # @param mise_bin [String]           Absolute path to the mise binary (ProgramArguments[0]).
        # @param ruby_bin [String]           Absolute path to the ruby to run the script under.
        # @param bin_path [String]           Absolute path to the src bin script.
        # @return [String]                   The full plist XML, ready to be written to disk and `plutil -lint`-validated.
        def call(label:, refresh_interval:, log_dir:, repo_root:, mise_toml:, mise_bin:, ruby_bin:, bin_path:)
          raise ArgumentError, "label is required" if label.to_s.empty?
          raise ArgumentError, "refresh_interval must be > 0" unless refresh_interval.is_a?(Integer) && refresh_interval > 0
          %w[log_dir repo_root mise_toml mise_bin ruby_bin bin_path].each do |k|
            v = binding.local_variable_get(k)
            raise ArgumentError, "#{k} must be absolute (got #{v.inspect})" unless v.is_a?(String) && File.absolute_path?(v)
          end

          out_log = File.join(log_dir, "#{label}.out.log")
          err_log = File.join(log_dir, "#{label}.err.log")

          body = +""
          body << key("Label") << string(label) << "\n"
          body << key("ProgramArguments") << "\n" << array([
            mise_bin,
            "exec",
            "--",
            ruby_bin,
            bin_path,
            "sync"
          ])
          body << key("WorkingDirectory") << string(repo_root) << "\n"
          body << key("EnvironmentVariables") << "\n" << dict({
            "MISE_CONFIG_FILE" => mise_toml
          })
          body << key("StartInterval") << integer(refresh_interval) << "\n"
          body << key("RunAtLoad") << boolean(true) << "\n"
          body << key("ProcessType") << string("Background") << "\n"
          body << key("StandardOutPath") << string(out_log) << "\n"
          body << key("StandardErrorPath") << string(err_log) << "\n"

          HEADER + body + FOOTER
        end

        private

        def key(name)
          "  <key>#{escape(name)}</key>\n"
        end

        # XML-escape: & must be first, then <, >, " and ' in attribute values
        # (we only emit element text, but be safe for both).
        def escape(s)
          s.to_s
            .gsub("&", "&amp;")
            .gsub("<", "&lt;")
            .gsub(">", "&gt;")
            .gsub("\"", "&quot;")
            .gsub("'", "&apos;")
        end

        def string(s)
          "  <string>#{escape(s)}</string>"
        end

        def integer(i)
          "  <integer>#{Integer(i)}</integer>"
        end

        def boolean(b)
          "  <#{b ? "true" : "false"}/>"
        end

        def array(items)
          out = +"  <array>\n"
          items.each { |arg| out << "    <string>#{escape(arg)}</string>\n" }
          out << "  </array>"
        end

        def dict(hash)
          out = +"  <dict>\n"
          hash.each do |k, v|
            out << "    <key>#{escape(k)}</key>\n"
            out << "    <string>#{escape(v)}</string>\n"
          end
          out << "  </dict>"
        end
      end
    end
  end
end

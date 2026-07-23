# frozen_string_literal: true

module Space::Architect
  module SessionSync
    # Hand-rolled launchd plist emitter for the session-sync agent, imitating
    # Space::Src::Launchd::Plist's shape. Under launchd's bare PATH, a bare
    # env-relative ruby binstub shebang resolves to macOS system Ruby instead
    # of the caller's toolchain, so ProgramArguments names the interpreter
    # explicitly (ruby_bin) rather than relying on shebang resolution — no
    # mise wrapping needed, since the sync itself pins no toolchain at run
    # time.
    class Plist
      DEFAULT_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

      HEADER = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
      XML
      FOOTER = "</dict>\n</plist>\n"

      class << self
        # @param label [String]            The job label (reverse-DNS; on-disk plist basename).
        # @param refresh_interval [Integer] StartInterval in seconds (must be > 0).
        # @param log_dir [String]          Absolute directory for stdout/stderr logs.
        # @param bin_path [String]         Absolute path to the architect bin script.
        # @param ruby_bin [String]         Absolute path to the ruby to run bin_path under.
        # @param host [String]             --host value passed to `sessions sync`.
        # @param env [Hash]                EnvironmentVariables dict; must contain a non-empty
        #                                  SessionSync::TOKEN_ENV value (resolved by the caller —
        #                                  never resolved here). PATH defaults to DEFAULT_PATH
        #                                  unless the caller supplies its own.
        # @return [String] the full plist XML.
        def call(label:, refresh_interval:, log_dir:, bin_path:, ruby_bin:, host:, env:)
          raise ArgumentError, "label is required" if label.to_s.empty?
          raise ArgumentError, "refresh_interval must be > 0" unless refresh_interval.is_a?(Integer) && refresh_interval > 0
          %w[log_dir bin_path ruby_bin].each do |k|
            v = binding.local_variable_get(k)
            raise ArgumentError, "#{k} must be absolute (got #{v.inspect})" unless v.is_a?(String) && File.absolute_path?(v)
          end
          raise ArgumentError, "host is required" if host.to_s.empty?
          raise ArgumentError, "env[#{SessionSync::TOKEN_ENV}] is required" if env.to_h[SessionSync::TOKEN_ENV].to_s.empty?

          out_log = File.join(log_dir, "#{label}.out.log")
          err_log = File.join(log_dir, "#{label}.err.log")

          body = +""
          body << key("Label") << string(label) << "\n"
          body << key("ProgramArguments") << "\n" << array([
            ruby_bin,
            bin_path,
            "sessions",
            "sync",
            "--host", host
          ])
          body << key("EnvironmentVariables") << "\n" << dict({"PATH" => DEFAULT_PATH}.merge(env.to_h))
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

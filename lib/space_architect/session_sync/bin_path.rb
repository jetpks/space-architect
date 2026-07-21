# frozen_string_literal: true

require "open3"

module Space::Architect
  module SessionSync
    # Resolves the absolute path to the `architect` executable the plist
    # should invoke, imitating Space::Src::CLI::Daemon::Helpers::Resolve's
    # detect_bin_path precedence: an env override (tests), the dev checkout's
    # exe/architect, `which architect`, then the installed gem's bin.
    module BinPath
      module_function

      def detect(env: ENV)
        override = env["SPACE_ARCHITECT_BIN_PATH"]
        return override if override && !override.empty?

        dev = File.expand_path("../../../exe/architect", __dir__)
        return dev if File.exist?(dev)

        out, _err, status = Open3.capture3("which", "architect")
        return out.strip if status.success? && !out.strip.empty?

        Gem.bin_path("space-architect", "architect")
      end
    end
  end
end

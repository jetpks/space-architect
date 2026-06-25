# frozen_string_literal: true

require "fileutils"

module Space::Src
  # One-shot data-preserving migration from the `repo-tender` identity
  # to `space-src`. Invoked from CLI.run before dispatch on every run;
  # all operations are idempotent so repeated invocations are safe.
  class Migration
    OLD_APP_NAME = "repo-tender"
    OLD_LABEL = "io.github.jetpks.repo-tender.sync"

    # Move old-identity XDG dirs to new-identity locations if the old
    # ones exist and the new ones do not (no-clobber — no data loss).
    # Print a one-line notice to `err` only when something is actually
    # moved. Also warn if the old-label launchd plist is still present
    # so the user knows to run `src daemon install`.
    def self.run(paths:, err:)
      moved = false

      old_config = File.join(paths.config_home, OLD_APP_NAME)
      new_config = paths.config_dir
      if File.directory?(old_config) && !File.exist?(new_config)
        FileUtils.mv(old_config, new_config)
        moved = true
      end

      old_state = File.join(paths.state_home, OLD_APP_NAME)
      new_state = paths.state_dir
      if File.directory?(old_state) && !File.exist?(new_state)
        FileUtils.mv(old_state, new_state)
        moved = true
      end

      err.puts "space-src: migrated config/state from #{OLD_APP_NAME}" if moved

      old_plist = File.join(paths.launch_agents_dir, "#{OLD_LABEL}.plist")
      if File.exist?(old_plist)
        err.puts "space-src: stale launchd agent found (#{OLD_LABEL}); run `src daemon install` to upgrade"
      end
    end
  end
end

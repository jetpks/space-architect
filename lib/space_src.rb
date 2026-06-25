# frozen_string_literal: true

require "space_src/version"

# repo-tender — keep local git clones evergreen.
# (clean · on the remote's default branch · fetched within refresh_interval)
#
# Slice 1 surface: Paths, Shell, Config::{Model,Contract,Store},
# State::Store, SCM::{Client,Git,Status}, Forge::{Client,GitHub}.
# Later slices build sync orchestration, CLI, and launchd on top.

module Space::Src
end

require "space_src/paths"
require "space_src/shell"
require "space_src/config/model"
require "space_src/config/contract"
require "space_src/config/store"
require "space_src/state/store"
require "space_src/state/lock"
require "space_src/scm/client"
require "space_src/scm/status"
require "space_src/scm/git"
require "space_src/forge/client"
require "space_src/forge/github"
require "space_src/sync/repo_plan"
require "space_src/sync/engine"
require "space_src/config/duration"
require "space_src/log_rotator"
require "space_src/launchd/plist"
require "space_src/launchd/agent"
require "space_src/ui/reporter"
require "space_src/ui/mode"
require "space_src/ui/plain_reporter"
require "space_src/ui/json_reporter"
require "space_src/cli"

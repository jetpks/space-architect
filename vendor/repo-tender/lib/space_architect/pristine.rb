# frozen_string_literal: true

require "space_architect/pristine/version"

# repo-tender — keep local git clones evergreen.
# (clean · on the remote's default branch · fetched within refresh_interval)
#
# Slice 1 surface: Paths, Shell, Config::{Model,Contract,Store},
# State::Store, SCM::{Client,Git,Status}, Forge::{Client,GitHub}.
# Later slices build sync orchestration, CLI, and launchd on top.

module SpaceArchitect::Pristine
end

require "space_architect/pristine/paths"
require "space_architect/pristine/shell"
require "space_architect/pristine/config/model"
require "space_architect/pristine/config/contract"
require "space_architect/pristine/config/store"
require "space_architect/pristine/state/store"
require "space_architect/pristine/state/lock"
require "space_architect/pristine/scm/client"
require "space_architect/pristine/scm/status"
require "space_architect/pristine/scm/git"
require "space_architect/pristine/forge/client"
require "space_architect/pristine/forge/github"
require "space_architect/pristine/sync/repo_plan"
require "space_architect/pristine/sync/engine"
require "space_architect/pristine/config/duration"
require "space_architect/pristine/log_rotator"
require "space_architect/pristine/launchd/plist"
require "space_architect/pristine/launchd/agent"
require "space_architect/pristine/ui/reporter"
require "space_architect/pristine/ui/mode"
require "space_architect/pristine/ui/plain_reporter"
require "space_architect/pristine/ui/json_reporter"
require "space_architect/pristine/cli"

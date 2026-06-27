# frozen_string_literal: true

require "space_core/version"

module Space::Core
end

require "space_core/errors"
require "space_core/warnings"
Space::Core::Warnings.disable_experimental!
require "space_core/atomic_write"
require "space_core/xdg"
require "space_core/config"
require "space_core/state"
require "space_core/slugger"
require "space_core/space"
require "space_core/repo_reference"
require "space_core/repo_resolver"
require "space_core/git_client"
require "space_core/mise_client"
require "space_core/space_store"
require "space_core/shell_integration"
require "space_core/terminal"
require "space_core/cli"

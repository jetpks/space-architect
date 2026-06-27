# frozen_string_literal: true

# Minimal bootstrap for runs unit tests — does NOT boot Hanami.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)

require "space/server/runs"
require "minitest/autorun"

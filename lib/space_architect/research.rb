# frozen_string_literal: true

module Space::Architect
  module Research
    READONLY_TOOLS = "Read,Grep,Glob,WebSearch,WebFetch"
  end
end

require_relative "research/run"
require_relative "research/registry"
require_relative "research/renderer"
require_relative "research/mux"
require_relative "research/supervisor"

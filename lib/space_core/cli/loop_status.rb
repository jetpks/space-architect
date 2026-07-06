# frozen_string_literal: true

module Space::Core::CLI
  # Compact Architect-Loop status block, derived from a space's own `project`
  # block in space.yaml — so this carries NO dependency on space_architect. It
  # is shared by the `architect --help` embed and the `space status` report.
  # Returns plain lines (callers colourise) and never raises on malformed data.
  module LoopStatus
    module_function

    # Lines for the compact block, or nil when there is no `project` block.
    def lines(project)
      return nil unless project.is_a?(Hash) && !project.empty?

      rows = ["Project status:  #{project["status"] || "(none)"}"]
      iter = current_iteration(project)
      rows << "Iteration:       #{ordinal(iter)} #{iter["name"]} — #{state_of(iter)}" if iter
      rows
    end

    def current_iteration(project)
      name = project["current_iteration"]
      return nil unless name

      Array(project["iterations"]).find { |s| s["name"] == name }
    end

    def ordinal(iter)
      iter["ordinal"] ? format("I%02d", iter["ordinal"]) : "I--"
    end

    # Derived loop state for the current iteration. Mirrors the precedence in
    # `architect status`: a decided verdict wins, then an integrated lane
    # (awaiting-verdict), then dispatched lanes, then a bare freeze, else spec.
    def state_of(iter)
      verdict = iter["verdict"]
      return verdict if verdict && verdict != "pending"

      lanes = Array(iter["lanes"])
      return "awaiting-verdict" if lanes.any? { |l| l["integration_branch"] }
      return "dispatched" if lanes.any?
      return "frozen #{iter["freeze_sha"][0, 8]}" if iter["freeze_sha"]

      "speccing"
    end
  end
end

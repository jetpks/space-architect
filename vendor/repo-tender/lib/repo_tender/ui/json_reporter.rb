# frozen_string_literal: true

require "json"
require "time"

module RepoTender
  module UI
    # Emits one JSON object per event line (12-factor style) to `out`.
    # Every object carries at minimum: "event", "t" (ISO8601 timestamp),
    # plus event-specific keys (ref, status, error, total, summary).
    # @out.sync = true ensures output is immediate on non-TTY pipes (GS5).
    class JsonReporter
      def initialize(out)
        @out = out
        @out.sync = true
      end

      def attach(task) = nil
      def detach = nil

      def listing_started(total:) = emit(event: "listing_started", total: total)
      def org_listed(ref, count:) = emit(event: "org_listed", org: ref.name, count: count)
      def listing_finished = emit(event: "listing_finished")

      def run_started(total:) = emit(event: "run_started", total: total)
      def repo_started(ref) = emit(event: "repo_started", ref: ref)
      def repo_phase(ref, phase) = emit(event: "repo_phase", ref: ref, phase: phase)
      def repo_finished(ref, status, action:, commits: 0) = emit(event: "repo_finished", ref: ref, status: status, action: action, commits: commits)
      def repo_failed(ref, error) = emit(event: "repo_failed", ref: ref, error: error.to_s)
      def run_finished(summary) = emit(event: "run_finished", summary: summary)

      private

      def emit(payload)
        @out.puts JSON.generate(payload.merge(t: Time.now.iso8601))
      end
    end
  end
end

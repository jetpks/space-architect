# frozen_string_literal: true

require "json"
require "time"

module RepoTender
  module UI
    # Emits one JSON object per event line (12-factor style) to `out`.
    # Every object carries at minimum: "event", "t" (ISO8601 timestamp),
    # plus event-specific keys (ref, status, error, total, summary).
    # attach/detach are no-ops (render fiber is Slice B).
    class JsonReporter
      def initialize(out)
        @out = out
      end

      def run_started(total:) = emit(event: "run_started", total: total)
      def repo_started(ref) = emit(event: "repo_started", ref: ref)
      def repo_phase(ref, phase) = emit(event: "repo_phase", ref: ref, phase: phase)
      def repo_finished(ref, status) = emit(event: "repo_finished", ref: ref, status: status)
      def repo_failed(ref, error) = emit(event: "repo_failed", ref: ref, error: error.to_s)
      def run_finished(summary) = emit(event: "run_finished", summary: summary)
      def attach(task, total:) = nil
      def detach = nil

      private

      def emit(payload)
        @out.puts JSON.generate(payload.merge(t: Time.now.iso8601))
      end
    end
  end
end

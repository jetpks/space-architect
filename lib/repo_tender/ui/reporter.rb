# frozen_string_literal: true

module RepoTender
  module UI
    # The reporter event interface. Every implementation must respond to:
    #
    #   run_started(total:)         # N repos about to process
    #   repo_started(ref)           # work begins on ref ("host/owner/name" string)
    #   repo_phase(ref, phase)      # :cloning | :fast_forwarding | :switching
    #   repo_finished(ref, status)  # final status string (matches state row)
    #   repo_failed(ref, error)     # failure string (plan error or unhandled raise)
    #   run_finished(summary)       # Hash<String,Integer> status→count
    #   attach(task, total:)        # Slice B: spawn render-loop fiber as child of task
    #   detach                      # Slice B: stop render fiber, restore terminal
    #
    # In Slice A, attach and detach are no-ops on every reporter.
    # The ref argument is always the string "host/owner/name" key.
    #
    # Implementations:
    #   NullReporter         — all no-ops; the engine default
    #   PlainReporter        — one ANSI-free line per terminal event
    #   JsonReporter         — one JSON object per event line (12-factor)
    #   InteractiveReporter  — Slice B: color + animated progress

    class NullReporter
      def run_started(total:) = nil
      def repo_started(ref) = nil
      def repo_phase(ref, phase) = nil
      def repo_finished(ref, status) = nil
      def repo_failed(ref, error) = nil
      def run_finished(summary) = nil
      def attach(task, total:) = nil
      def detach = nil
    end
  end
end

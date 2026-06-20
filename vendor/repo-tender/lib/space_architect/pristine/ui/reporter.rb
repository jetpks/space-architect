# frozen_string_literal: true

module SpaceArchitect::Pristine
  module UI
    # The reporter event interface. Every implementation must respond to:
    #
    #   attach(task)                # spawn render-loop fiber as child of task
    #                               # called BEFORE listing begins; no total yet
    #   listing_started(total:)     # N orgs about to be listed
    #   org_listed(ref, count:)     # one per org as it finishes listing;
    #                               #   ref is OrgRef; count: nil on failure
    #   listing_finished            # all orgs listed (or skipped on auth failure)
    #   run_started(total:)         # N repos about to be processed
    #   repo_started(ref)           # work begins on ref ("host/owner/name" string)
    #   repo_phase(ref, phase)      # :cloning | :fast_forwarding | :switching
    #   repo_finished(ref, status, action:, commits: 0)
    #                               # final status string (matches state row);
    #                               # action: realized-action Symbol; commits: Integer
    #   repo_failed(ref, error)     # failure string (plan error or unhandled raise)
    #   run_finished(summary)       # Hash<String,Integer> status→count
    #   detach                      # stop render fiber, restore terminal
    #
    # Engine event sequence:
    #   attach(task) → listing_started(total:) → {org_listed(ref, count:)} →
    #   listing_finished → run_started(total:) → {repo_started → repo_phase* →
    #   repo_finished|repo_failed} → run_finished(summary) → detach
    #
    # Implementations:
    #   NullReporter         — all no-ops; the engine default
    #   PlainReporter        — one ANSI-free line per terminal event
    #   JsonReporter         — one JSON object per event line (12-factor)
    #   InteractiveReporter  — color + animated progress (two-phase: listing + sweep)

    class NullReporter
      def attach(task) = nil
      def listing_started(total:) = nil
      def org_listed(ref, count:) = nil
      def listing_finished = nil
      def run_started(total:) = nil
      def repo_started(ref) = nil
      def repo_phase(ref, phase) = nil
      def repo_finished(ref, status, action:, commits: 0) = nil
      def repo_failed(ref, error) = nil
      def run_finished(summary) = nil
      def detach = nil
    end
  end
end

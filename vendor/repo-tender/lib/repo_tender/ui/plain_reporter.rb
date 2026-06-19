# frozen_string_literal: true

module RepoTender
  module UI
    # Emits one tab-separated line per terminal repo event, ANSI-free always.
    # repo_finished → "ref\tstatus"; repo_failed → "ref\tFAILED\terror".
    # org_listed → "listed: ref.name\tN repos" (or "listed: ref.name\tFAILED" on failure).
    # Both write to the same `out` stream (G4 choice: no separate stderr stream
    # in Slice A; FAILED marker distinguishes errors).
    # @out.sync = true ensures output is immediate on non-TTY pipes (GS5).
    class PlainReporter
      def initialize(out, mode: nil)
        @out = out
        @out.sync = true
      end

      def attach(task) = nil
      def detach = nil

      def listing_started(total:)
        @out.puts "listing: #{total} org(s)"
      end

      def org_listed(ref, count:)
        if count
          @out.puts "listed: #{ref.name}\t#{count} repo(s)"
        else
          @out.puts "listed: #{ref.name}\tFAILED"
        end
      end

      def listing_finished = nil

      def run_started(total:)
        @out.puts "starting: #{total} repo(s)"
      end

      def repo_started(ref) = nil

      def repo_phase(ref, phase) = nil

      def repo_finished(ref, status, action:, commits: 0)
        @out.puts "#{ref}\t#{status}"
      end

      def repo_failed(ref, error)
        @out.puts "#{ref}\tFAILED\t#{error}"
      end

      def run_finished(summary) = nil
    end
  end
end

# frozen_string_literal: true

module RepoTender
  module UI
    # Emits one tab-separated line per terminal repo event, ANSI-free always.
    # repo_finished → "ref\tstatus"; repo_failed → "ref\tFAILED\terror".
    # Both write to the same `out` stream (G4 choice: no separate stderr stream
    # in Slice A; FAILED marker distinguishes errors).
    # attach/detach are no-ops (render fiber is Slice B).
    class PlainReporter
      def initialize(out, mode: nil)
        @out = out
      end

      def run_started(total:)
        @out.puts "starting: #{total} repo(s)"
      end

      def repo_started(ref) = nil

      def repo_phase(ref, phase) = nil

      def repo_finished(ref, status)
        @out.puts "#{ref}\t#{status}"
      end

      def repo_failed(ref, error)
        @out.puts "#{ref}\tFAILED\t#{error}"
      end

      def run_finished(summary) = nil

      def attach(task, total:) = nil
      def detach = nil
    end
  end
end

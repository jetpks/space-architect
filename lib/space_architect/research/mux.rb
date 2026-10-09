# frozen_string_literal: true

require "json"

module Space::Architect
  module Research
    # Async multiplexer: one fiber per in-flight run, each tailing its run.jsonl.
    # Uses socketry/async fibers — NEVER threads.
    class Mux
      POLL_INTERVAL    = 0.15  # seconds between read attempts
      HEARTBEAT_EVERY  = 30    # seconds of silence before heartbeat
      FILE_WAIT_LIMIT  = 10    # seconds to wait for run.jsonl to appear

      # heartbeat_every: test seam — defaults to HEARTBEAT_EVERY.
      def initialize(runs, renderer:, out: $stdout, heartbeat_every: HEARTBEAT_EVERY)
        @runs            = runs
        @renderer        = renderer
        @out             = out
        @heartbeat_every = heartbeat_every
      end

      # Returns :ok or :failed
      def run
        results = Sync do
          tasks = @runs.map do |run|
            Async { tail_run(run) }
          end
          tasks.map(&:wait)
        end

        results.all? { |r| r == :ok } ? :ok : :failed
      end

      private

      def tail_run(run)
        wait_for_file(run)

        unless File.exist?(run.run_log_path.to_s)
          emit(@renderer.terminal(lane: run.id, ok: false, reason: "run.jsonl never appeared"))
          return :failed
        end

        emit(@renderer.render(lane: run.id, events: [], alive: true))

        events_all = []
        last_emit  = Time.now
        settled    = nil

        File.open(run.run_log_path.to_s, "r") do |f|
          loop do
            line = f.gets
            if line && !line.strip.empty?
              ev = begin; JSON.parse(line.chomp); rescue JSON::ParserError; nil; end
              next unless ev

              events_all << ev
              settled = ev if ev["type"] == "agent_settled"

              new_events = [ev]
              rendered = @renderer.render(lane: run.id, events: new_events, alive: settled.nil?)
              emit(rendered) unless rendered.empty?
              last_emit = Time.now

              break if settled
            else
              # EOF — check liveness
              pid_alive = begin; Process.kill(0, run.pid); true; rescue Errno::ESRCH, Errno::EPERM; false; end

              unless pid_alive
                # PID dead and no terminal event → treat as failure
                unless settled
                  emit(@renderer.terminal(lane: run.id, ok: false,
                                          reason: "process died without a terminal event"))
                  return :failed
                end
                break
              end

              if Time.now - last_emit > @heartbeat_every
                emit("[#{run.id}] ⏳ still running…\n") if @renderer.lifecycle?
                last_emit = Time.now
              end

              sleep POLL_INTERVAL
            end
          end
        end

        finish(run, events_all, settled)
      end

      # Classify the settled stream via PiEvents and render the terminal line.
      def finish(run, events, settled)
        text   = PiEvents.message_text(PiEvents.last_assistant_message(events))
        outcome, reason = classify(events, settled, text)

        extract_report(run, text) unless text.empty?

        emit(@renderer.terminal(lane: run.id, ok: outcome == :ok,
                                reason:  outcome == :ok ? nil : reason,
                                snippet: outcome == :ok ? text : nil,
                                duration: PiEvents.duration_seconds(events),
                                turns:    PiEvents.turn_count(events)))
        outcome
      end

      # :ok iff the stream settled un-aborted, the last assistant stopReason is
      # "stop", and the final assistant text is non-empty; :failed with a named
      # reason otherwise.
      def classify(events, settled, text)
        reason = PiEvents.stop_reason(events)

        return [:failed, text.empty? ? "aborted" : text] if settled.is_a?(Hash) && settled["aborted"] == true
        return [:ok, text] if reason == "stop" && !text.empty?
        return [:failed, text.empty? ? reason : text] if PiEvents.failed_stop_reason?(reason)

        # "stop" or no assistant message at all, but no final text.
        [:failed, "no final assistant text"]
      end

      def wait_for_file(run)
        deadline = Time.now + FILE_WAIT_LIMIT
        until File.exist?(run.run_log_path.to_s) || Time.now > deadline
          pid_alive = begin; Process.kill(0, run.pid); true; rescue Errno::ESRCH, Errno::EPERM; false; end
          break unless pid_alive
          sleep 0.05
        end
      end

      def extract_report(run, text)
        Pathname.new(run.report_path).write(text)
      end

      def emit(text)
        return if text.nil? || text.empty?
        @out.print(text)
        @out.flush if @out.respond_to?(:flush)
      end
    end
  end
end

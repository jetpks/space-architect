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

      def initialize(runs, renderer:, out: $stdout)
        @runs     = runs
        @renderer = renderer
        @out      = out
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
          emit(@renderer.render(lane: run.id, events: [error_event("run.jsonl never appeared")], alive: false))
          return :failed
        end

        emit(@renderer.render(lane: run.id, events: [], alive: true))

        events_all = []
        last_emit  = Time.now
        terminal   = nil

        File.open(run.run_log_path.to_s, "r") do |f|
          loop do
            line = f.gets
            if line && !line.strip.empty?
              ev = begin; JSON.parse(line.chomp); rescue JSON::ParserError; nil; end
              next unless ev

              events_all << ev
              terminal = ev if ev["type"] == "result"

              new_events = [ev]
              rendered = @renderer.render(lane: run.id, events: new_events, alive: terminal.nil?)
              emit(rendered) unless rendered.empty?
              last_emit = Time.now

              break if terminal
            else
              # EOF — check liveness
              pid_alive = begin; Process.kill(0, run.pid); true; rescue Errno::ESRCH, Errno::EPERM; false; end

              unless pid_alive
                # PID dead and no terminal event → treat as failure
                unless terminal
                  emit(@renderer.render(lane: run.id,
                                        events: [error_event("process died without result event")],
                                        alive: false))
                  return :failed
                end
                break
              end

              if Time.now - last_emit > HEARTBEAT_EVERY
                emit("[#{run.id}] ⏳ still running…\n") if @renderer.instance_variable_get(:@level).to_i >= 1 &&
                                                           !@renderer.instance_variable_get(:@jsonl)
                last_emit = Time.now
              end

              sleep POLL_INTERVAL
            end
          end
        end

        if terminal
          extract_report(run, terminal)
          rendered = @renderer.render(lane: run.id, events: [terminal], alive: false)
          emit(rendered) unless rendered.empty?
          terminal["is_error"] ? :failed : :ok
        else
          :failed
        end
      end

      def wait_for_file(run)
        deadline = Time.now + FILE_WAIT_LIMIT
        until File.exist?(run.run_log_path.to_s) || Time.now > deadline
          pid_alive = begin; Process.kill(0, run.pid); true; rescue Errno::ESRCH, Errno::EPERM; false; end
          break unless pid_alive
          sleep 0.05
        end
      end

      def extract_report(run, terminal_ev)
        result = terminal_ev["result"].to_s
        return if result.empty?

        Pathname.new(run.report_path).write(result)
      end

      def error_event(msg)
        { "type" => "result", "subtype" => "error", "is_error" => true,
          "duration_ms" => 0, "num_turns" => 0, "result" => msg }
      end

      def emit(text)
        return if text.nil? || text.empty?
        @out.print(text)
        @out.flush if @out.respond_to?(:flush)
      end
    end
  end
end

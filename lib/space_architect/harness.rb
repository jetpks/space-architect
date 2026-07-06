# frozen_string_literal: true

require "async/process"
require "async/http/client"
require "async/http/endpoint"
require "protocol/http/body/writable"
require "json"
require "pathname"
require "uri"

module Space::Architect
  module Harness
    CLAUDE_DEFAULT_MODEL = "claude-sonnet-4-6"

    # Factory keyed by harness name.
    # For opencode: config_dir is required (build/<id>-<lane> dir outside the worktree).
    def self.for(name, model:, max_turns:, bin: nil, config_dir: nil, effort: nil)
      case name.to_s
      when "claude-code"
        if effort
          raise Space::Core::Error,
            "effort is opencode-only (sets opencode reasoningEffort) — " \
            "claude-code effort is set via the prompt"
        end
        ClaudeCodeHarness.new(model: model, max_turns: max_turns, bin: bin)
      when "opencode"
        if model == CLAUDE_DEFAULT_MODEL
          raise Space::Core::Error,
            "Pass --model when using --harness opencode (the claude-sonnet-4-6 default " \
            "is a Claude model ID and will not work with opencode — " \
            "try e.g. fireworks-ai/accounts/fireworks/models/glm-5p2)"
        end
        raise Space::Core::Error, "config_dir is required for opencode harness" unless config_dir
        OpenCodeHarness.new(model: model, max_turns: max_turns, bin: bin, config_dir: config_dir, effort: effort)
      else
        raise Space::Core::Error, "Unknown harness '#{name}' — valid values: claude-code, opencode"
      end
    end

    class ClaudeCodeHarness
      ALLOWED_TOOLS    = "Read,Edit,Write,Grep,Glob,Bash,WebSearch,WebFetch"
      DISALLOWED_TOOLS = [
        "Bash(git commit:*)", "Bash(git push:*)", "Bash(git reset:*)",
        "Bash(git merge:*)",  "Bash(git rebase:*)", "Bash(git checkout:*)",
        "Bash(git branch:*)"
      ].join(",")

      def initialize(model:, max_turns:, bin: nil,
                     allowed_tools: ALLOWED_TOOLS, disallowed_tools: DISALLOWED_TOOLS)
        @model            = model
        @max_turns        = max_turns
        @bin              = bin || ENV.fetch("ARCHITECT_CLAUDE_BIN", "claude")
        @allowed_tools    = allowed_tools
        @disallowed_tools = disallowed_tools
      end

      TIMEOUT_EXIT_CODE = 124

      # How long the liveness fiber waits before reading the run log's stream-json init
      # event. Injectable via the run(liveness_delay:) kwarg so tests need not sleep seconds.
      LIVENESS_DELAY_SECONDS = 5.0

      def run(prompt_path:, run_log_path:, chdir:, push_url: nil, push_token: nil, push_client: nil, timeout: nil,
              liveness_delay: LIVENESS_DELAY_SECONDS, err: $stderr)
        prompt_path  = Pathname.new(prompt_path)
        run_log_path = Pathname.new(run_log_path)

        File.open(prompt_path, "r") do |prompt_io|
          File.open(run_log_path, "w") do |log|
            r, w = IO.pipe
            Sync do
              child = Async::Process::Child.new(*argv, chdir: chdir.to_s, in: prompt_io, out: w, err: log)
              w.close
              tasks = start_tee(r, log, push_url: push_url, push_token: push_token, push_client: push_client, err: err)
              timed_out    = false
              timeout_task = nil

              # Async::Task#with_timeout cannot do TERM→grace→KILL because
              # Async::Process::Child#wait_thread's ensure goes straight to KILL.
              # Instead: a concurrent fiber fires after the deadline and escalates.
              # transient: true so the reactor doesn't wait for it when main work finishes.
              if timeout && timeout > 0
                timeout_task = Async(transient: true) do
                  sleep timeout
                  timed_out = true
                  Process.kill("TERM", -child.pid) rescue nil
                  sleep 0.5
                  Process.kill("KILL", -child.pid) rescue nil
                end
              end

              # Liveness self-check: after a bounded delay, read the run log's stream-json
              # init event and print ONE line naming the streamed model + confirming growth.
              # transient: true so it never keeps the reactor alive; best-effort so it never
              # raises into the run path. run_detached gets no such fiber.
              liveness_task = nil
              if liveness_delay && liveness_delay > 0
                liveness_task = Async(transient: true) do
                  sleep liveness_delay
                  emit_liveness(run_log_path, liveness_delay, err)
                end
              end

              status = child.wait
              timeout_task&.stop
              liveness_task&.stop

              tasks.each(&:wait)
              timed_out ? TIMEOUT_EXIT_CODE : status.exitstatus
            end
          end
        end
      end

      def run_detached(prompt_path:, run_log_path:, chdir:)
        prompt_path  = Pathname.new(prompt_path)
        run_log_path = Pathname.new(run_log_path)

        prompt_io = File.open(prompt_path, "r")
        log       = File.open(run_log_path, "w")
        begin
          pid = Process.spawn(*argv, chdir: chdir.to_s, pgroup: true,
                              in: prompt_io, out: log, err: log)
          Process.detach(pid)
        ensure
          prompt_io.close
          log.close
        end
        pid
      end

      private

      # Read the run log's stream-json init event and print exactly one bounded liveness
      # line to err. Best-effort: swallows any read/parse error so it never raises into run.
      def emit_liveness(run_log_path, delay, err)
        bytes = run_log_path.exist? ? run_log_path.size : 0
        if bytes.zero?
          err.puts "liveness: WARN no growth — run log still empty #{delay}s after dispatch"
          return
        end

        streamed = streamed_init_model(run_log_path)
        if streamed.nil?
          err.puts "liveness: WARN model unverified — no stream-json init event after #{delay}s (run log #{bytes} bytes)"
        elsif streamed == @model
          err.puts "liveness: OK streaming model=#{streamed} (run log growing, #{bytes} bytes)"
        else
          err.puts "liveness: WARN model mismatch — pinned=#{@model} streamed=#{streamed} (run log growing, #{bytes} bytes)"
        end
      rescue StandardError
        # Best-effort: an internal read/parse failure must never break the run.
      end

      # The model named by the stream-json init event ({"type":"system","subtype":"init",...}),
      # or nil if no such event has been logged yet.
      def streamed_init_model(run_log_path)
        run_log_path.each_line do |line|
          ev = begin
            JSON.parse(line)
          rescue JSON::ParserError
            next
          end
          next unless ev.is_a?(Hash) && ev["type"] == "system" && ev["subtype"] == "init"
          return ev["model"]
        end
        nil
      end

      def argv
        args = [
          @bin, "-p",
          "--model", @model,
          "--permission-mode", "acceptEdits",
          "--allowedTools", @allowed_tools,
          "--output-format", "stream-json",
          "--verbose",
          "--include-partial-messages",
          "--max-turns", @max_turns.to_s
        ]
        args += ["--disallowedTools", @disallowed_tools] unless @disallowed_tools.to_s.empty?
        args
      end

      def start_tee(r, log, push_url:, push_token:, push_client:, err: $stderr)
        if push_url || push_client
          body = Protocol::HTTP::Body::Writable.new(queue: Thread::SizedQueue.new(32))
          push = Async { push_body(body, push_url: push_url, push_token: push_token, push_client: push_client, err: err) }
          [Async { tee_pipe(r, log, body, err: err) }, push]
        else
          [Async { drain_pipe(r, log) }]
        end
      end

      def push_body(body, push_url:, push_token:, push_client:, err: $stderr)
        path    = push_url ? URI.parse(push_url).path : "/"
        headers = [["content-type", "application/x-ndjson"]]
        headers << ["authorization", "Bearer #{push_token}"] if push_token
        if push_client
          push_client.post(path, headers: headers, body: body).discard
        else
          Async::HTTP::Client.open(Async::HTTP::Endpoint.parse(push_url)) do |c|
            c.post(path, headers: headers, body: body).discard
          end
        end
      rescue StandardError => e
        err.puts "push_body: transport error (best-effort, run log intact): #{e.class}: #{e.message}"
      end

      def tee_pipe(r, log, body, err: $stderr)
        pushing = true
        while (chunk = r.gets)
          log.write(chunk)
          log.flush
          if pushing
            begin
              body.write(chunk)
            rescue StandardError => e
              err.puts "tee_pipe: push write failed (best-effort, continuing log): #{e.class}: #{e.message}"
              pushing = false
            end
          end
        end
      ensure
        body.close_write
        r.close
      end

      def drain_pipe(r, log)
        while (chunk = r.gets)
          log.write(chunk)
          log.flush
        end
      ensure
        r.close
      end
    end

    class OpenCodeHarness
      def initialize(model:, max_turns:, bin: nil, config_dir:, effort: nil)
        @model      = model
        @max_turns  = max_turns
        @bin        = bin || ENV.fetch("ARCHITECT_OPENCODE_BIN", "opencode")
        @config_dir = Pathname.new(config_dir)
        @effort     = effort
      end

      # Returns the agent config hash (deterministic, unit-testable).
      def builder_config
        cfg = {
          "agent" => {
            "builder" => {
              "steps" => @max_turns,
              "permission" => {
                "bash" => {
                  "git commit *"   => "deny",
                  "git push *"     => "deny",
                  "git reset *"    => "deny",
                  "git rebase *"   => "deny",
                  "git checkout *" => "deny",
                  "*"              => "allow"
                }
              }
            }
          }
        }
        cfg.merge!(reasoning_provider_config) if @effort
        cfg
      end

      def run(prompt_path:, run_log_path:, chdir:, timeout: nil) # timeout: deferred — opencode kill path is out of scope
        prompt_path  = Pathname.new(prompt_path)
        run_log_path = Pathname.new(run_log_path)
        config_path  = write_config

        env = {
          "OPENCODE_CONFIG"                 => config_path.to_s,
          "OPENCODE_DISABLE_PROJECT_CONFIG" => "1"
        }

        File.open(prompt_path, "r") do |prompt_io|
          File.open(run_log_path, "w") do |log|
            status = Sync do
              Async::Process.spawn(env, *argv(chdir),
                                   chdir: chdir.to_s, in: prompt_io, out: log, err: log)
            end
            status.exitstatus
          end
        end
      end

      def run_detached(prompt_path:, run_log_path:, chdir:)
        prompt_path  = Pathname.new(prompt_path)
        run_log_path = Pathname.new(run_log_path)
        config_path  = write_config

        env = {
          "OPENCODE_CONFIG"                 => config_path.to_s,
          "OPENCODE_DISABLE_PROJECT_CONFIG" => "1"
        }

        prompt_io = File.open(prompt_path, "r")
        log       = File.open(run_log_path, "w")
        begin
          pid = Process.spawn(env, *argv(chdir), chdir: chdir.to_s, pgroup: true,
                              in: prompt_io, out: log, err: log)
          Process.detach(pid)
        ensure
          prompt_io.close
          log.close
        end
        pid
      end

      private

      def reasoning_provider_config
        provider, model_id = @model.split("/", 2)
        {
          "provider" => {
            provider => {
              "models" => {
                model_id => { "options" => { "reasoningEffort" => @effort } }
              }
            }
          }
        }
      end

      def write_config
        path = @config_dir.join("opencode.json")
        path.write(JSON.generate(builder_config))
        path
      end

      # --dir sets the working directory for opencode's tooling layer.
      def argv(chdir)
        args = [
          @bin, "run",
          "--format", "json",
          "--model", @model,
          "--dangerously-skip-permissions",
          "--agent", "builder",
          "--dir", chdir.to_s
        ]
        args
      end
    end
  end
end

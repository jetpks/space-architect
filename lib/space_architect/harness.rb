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

    # The normalized internal thinking vocabulary — pi's fullest set. Every alias
    # (--effort/--thinking/--reasoning) is normalized to a member of this array;
    # each harness then translates + clamps down to its own flag's vocabulary.
    THINKING_LEVELS = %w[off minimal low medium high xhigh max].freeze

    def self.validate_thinking_level!(level)
      return if level.nil? || THINKING_LEVELS.include?(level)
      raise Space::Core::Error,
        "unknown thinking level '#{level}' — valid: #{THINKING_LEVELS.join(', ')}"
    end

    # Split a "model:level" id into [model, level] (level nil, model unchanged if no
    # suffix). Only a trailing segment that is a member of THINKING_LEVELS is treated
    # as a suffix — a model id containing a literal colon for another reason is left alone.
    def self.parse_model_suffix(model)
      return [model, nil] unless model
      base, _, suffix = model.rpartition(":")
      return [model, nil] if base.empty? || !THINKING_LEVELS.include?(suffix)
      [base, suffix]
    end

    # Per-harness translate + clamp: input a normalized level (or nil) and whether the
    # caller forced it (skips clamping — the literal is passed through unmodified).
    # Returns [translated_level_or_nil, inform_line_or_nil].
    def self.translate_thinking(harness, level, force: false)
      case harness.to_s
      when "claude-code" then ClaudeCodeHarness.translate_thinking(level, force: force)
      when "opencode"    then OpenCodeHarness.translate_thinking(level, force: force)
      when "pi"          then PiHarness.translate_thinking(level, force: force)
      else nil
      end
    end

    # Factory keyed by harness name. Translates + clamps the normalized `effort`
    # level to the harness's own vocabulary, printing one inform line to `err`
    # (default $stderr; thread a null writer to suppress) when it clamps/strips.
    # With force: true, the literal `effort` value is passed through unmodified.
    # For opencode: config_dir is required (build/<id>-<lane> dir outside the worktree).
    def self.for(name, model:, max_turns:, bin: nil, config_dir: nil, effort: nil, force: false, err: $stderr)
      translated, inform = translate_thinking(name, effort, force: force)
      err.puts(inform) if inform

      case name.to_s
      when "claude-code"
        ClaudeCodeHarness.new(model: model, max_turns: max_turns, bin: bin, effort: translated)
      when "opencode"
        if model == CLAUDE_DEFAULT_MODEL
          raise Space::Core::Error,
            "Pass --model when using --harness opencode (the claude-sonnet-4-6 default " \
            "is a Claude model ID and will not work with opencode — " \
            "try e.g. fireworks-ai/accounts/fireworks/models/glm-5p2)"
        end
        raise Space::Core::Error, "config_dir is required for opencode harness" unless config_dir
        OpenCodeHarness.new(model: model, max_turns: max_turns, bin: bin, config_dir: config_dir, effort: translated)
      when "pi"
        if model == CLAUDE_DEFAULT_MODEL
          raise Space::Core::Error,
            "Pass --model when using --harness pi " \
            "(#{CLAUDE_DEFAULT_MODEL} is a Claude model ID, not valid for pi — " \
            "try e.g. openrouter/qwen/qwen3-27b-optiq or local-inference/qwen3-27b-optiq)"
        end
        raise Space::Core::Error, "config_dir is required for pi harness" unless config_dir
        PiHarness.new(model: model, max_turns: max_turns, bin: bin, config_dir: config_dir, effort: translated)
      else
        raise Space::Core::Error, "Unknown harness '#{name}' — valid values: claude-code, opencode, pi"
      end
    end

    class ClaudeCodeHarness
      ALLOWED_TOOLS    = "Read,Edit,Write,Grep,Glob,Bash,WebSearch,WebFetch"
      DISALLOWED_TOOLS = [
        "Bash(git commit:*)", "Bash(git push:*)", "Bash(git reset:*)",
        "Bash(git merge:*)",  "Bash(git rebase:*)", "Bash(git checkout:*)",
        "Bash(git branch:*)"
      ].join(",")

      # claude-code's --effort accepts low/medium/high/xhigh/max; it has no off level
      # (stripped — omit --effort) and no minimal level (clamped to low).
      ACCEPTED_LEVELS = %w[low medium high xhigh max].freeze
      CLAMP_MAP = { "minimal" => "low" }.freeze

      def self.translate_thinking(level, force: false)
        return [nil, nil] if level.nil?
        return [level, "thinking: force --effort=#{level} (unmodified, may be rejected)"] if force
        return [level, nil] if ACCEPTED_LEVELS.include?(level)
        return [nil, "thinking: off → claude-code (no --effort; claude-code has no off level)"] if level == "off"

        clamped = CLAMP_MAP.fetch(level)
        [clamped, "thinking: #{level} → claude-code #{clamped} (clamped; claude-code has no #{level} level)"]
      end

      def initialize(model:, max_turns:, bin: nil, effort: nil,
                     allowed_tools: ALLOWED_TOOLS, disallowed_tools: DISALLOWED_TOOLS)
        @model            = model
        @max_turns        = max_turns
        @bin              = bin || ENV.fetch("ARCHITECT_CLAUDE_BIN", "claude")
        @effort           = effort
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
        args += ["--effort", @effort] if @effort
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
      # opencode's reasoningEffort accepts only low/medium/high; off/minimal are
      # stripped (omit reasoningEffort) and xhigh/max are clamped down to high.
      ACCEPTED_LEVELS = %w[low medium high].freeze
      CLAMP_MAP = { "xhigh" => "high", "max" => "high" }.freeze

      def self.translate_thinking(level, force: false)
        return [nil, nil] if level.nil?
        return [level, "thinking: force --effort=#{level} (unmodified, may be rejected)"] if force
        return [level, nil] if ACCEPTED_LEVELS.include?(level)

        if (clamped = CLAMP_MAP[level])
          [clamped, "thinking: #{level} → opencode #{clamped} (clamped; opencode accepts low/medium/high)"]
        else
          [nil, "thinking: #{level} → opencode (omitting reasoningEffort; opencode has no #{level} level)"]
        end
      end

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

    # `pi -p --mode json`, session redirected into the lane's build dir via --session-dir
    # (pi otherwise auto-saves under ~/.pi/agent/sessions/, organized by mangled CWD).
    class PiHarness
      TIMEOUT_EXIT_CODE = 124

      # pi's --thinking accepts the full normalized vocabulary unchanged — pi's own
      # per-model thinkingLevelMap clamps further; architect does not clamp for pi.
      def self.translate_thinking(level, force: false)
        return [nil, nil] if level.nil?
        return [level, "thinking: force --effort=#{level} (unmodified, may be rejected)"] if force
        [level, nil]
      end

      # max_turns is accepted for interface parity with the other harnesses but is
      # intentionally absent from argv — pi has no turn cap; the wall-clock timeout
      # (below) is the only bound on a run.
      def initialize(model:, max_turns:, bin: nil, config_dir:, effort: nil)
        @model      = model
        @bin        = bin || ENV.fetch("ARCHITECT_PI_BIN", "pi")
        @config_dir = Pathname.new(config_dir)
        @effort     = effort
      end

      def run(prompt_path:, run_log_path:, chdir:, timeout: nil, **)
        prompt_path  = Pathname.new(prompt_path)
        run_log_path = Pathname.new(run_log_path)

        File.open(prompt_path, "r") do |prompt_io|
          File.open(run_log_path, "w") do |log|
            Sync do
              child = Async::Process::Child.new(*argv, chdir: chdir.to_s, in: prompt_io, out: log, err: log)
              timed_out    = false
              timeout_task = nil

              # Same TERM→grace→KILL escalation as ClaudeCodeHarness — with: Async::Process::Child's
              # #wait_thread ensure goes straight to KILL, so a concurrent fiber does the escalation.
              if timeout && timeout > 0
                timeout_task = Async(transient: true) do
                  sleep timeout
                  timed_out = true
                  Process.kill("TERM", -child.pid) rescue nil
                  sleep 0.5
                  Process.kill("KILL", -child.pid) rescue nil
                end
              end

              status = child.wait
              timeout_task&.stop

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

      def argv
        args = [@bin, "-p", "--mode", "json", "--model", @model, "--session-dir", @config_dir.to_s, "--no-approve"]
        args += ["--thinking", @effort] if @effort
        args
      end
    end
  end
end

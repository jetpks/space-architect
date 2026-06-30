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

      def run(prompt_path:, run_log_path:, chdir:, push_url: nil, push_token: nil, push_client: nil, timeout: nil)
        prompt_path  = Pathname.new(prompt_path)
        run_log_path = Pathname.new(run_log_path)

        File.open(prompt_path, "r") do |prompt_io|
          File.open(run_log_path, "w") do |log|
            r, w = IO.pipe
            Sync do
              child = Async::Process::Child.new(*argv, chdir: chdir.to_s, in: prompt_io, out: w, err: log)
              w.close
              tasks = start_tee(r, log, push_url: push_url, push_token: push_token, push_client: push_client)
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

              status = child.wait
              timeout_task&.stop

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

      def start_tee(r, log, push_url:, push_token:, push_client:)
        if push_url || push_client
          body = Protocol::HTTP::Body::Writable.new(queue: Thread::SizedQueue.new(32))
          push = Async { push_body(body, push_url: push_url, push_token: push_token, push_client: push_client) }
          [Async { tee_pipe(r, log, body) }, push]
        else
          [Async { drain_pipe(r, log) }]
        end
      end

      def push_body(body, push_url:, push_token:, push_client:)
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
        $stderr.puts "push_body: transport error (best-effort, run log intact): #{e.class}: #{e.message}"
      end

      def tee_pipe(r, log, body)
        pushing = true
        while (chunk = r.gets)
          log.write(chunk)
          log.flush
          if pushing
            begin
              body.write(chunk)
            rescue StandardError => e
              $stderr.puts "tee_pipe: push write failed (best-effort, continuing log): #{e.class}: #{e.message}"
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

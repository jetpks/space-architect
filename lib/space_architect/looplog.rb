# frozen_string_literal: true

require "json"
require "time"
require "find"
require_relative "loop_cost"

module Space
  module Architect
    # looplog — follow every active pi-subagents run in a space, live. A
    # faithful port of the pi-port bin/looplog (the byte-compat oracle; same
    # display bytes), module-ized under Space::Architect.
    #
    #   architect looplog              # follow active runs as they stream
    #   architect looplog --list       # inventory only (active/age/size/agent per run)
    #   architect looplog --replay     # print existing history on adoption, then follow
    #   architect looplog --all        # adopt every transcript, however stale
    #   architect looplog my-space     # default: nearest ancestor with space.yaml
    #
    # The source is pi-subagents' artifact transcripts —
    # <session-dir>/**/subagent-artifacts/<runid>_<agent>_transcript.jsonl,
    # nested session dirs included — from TWO roots: pi's default sessions dir
    # for the space slug (agents spawned with cwd = the space) AND the space's
    # build/ tree (the loop launches coordinators from headless
    # `pi -p --session-dir build/loop/<launch>/` bootstraps, so the coordinator,
    # its spec/builder/judge children, and deeper descendants all live inside
    # the space — lane worktrees are pruned). Records are message-granularity:
    # runlog's display discipline carries over — thinking dim, assistant text
    # plain, tool calls one-lined with their args, results one-lined with a
    # line count, ✓ done / ✗ failed with usage summed across the exchange, and
    # truncation at RUNLOG_LIMIT (default 2000) characters. Followed lines carry
    # the record's own timestamp (HH:MM:SS local) after the run tag; --list
    # shows last-activity HH:MM beside the age. Thinking text is NOT truncated —
    # set RUNLOG_THINK to clamp it if a run goes feral.
    #
    # [I95 loop-parity] tart records read alongside the pi roots, same
    # rendering (B-Laws 1–4): the tart subagents home (~/.tart/subagents, run
    # dirs identified by status.json, transcript = the newest
    # <run>/sessions/**/*.jsonl) and the tart sessions root (~/.tart/sessions)
    # narrowed to the space slug — agent-less session files list under the
    # gem's existing "(session)" label (LoopCost::SESSION_AGENT). Both roots
    # carry the gem's own reader-side env overrides (TART_SUBAGENTS_HOME /
    # TART_SESSIONS_DIR, mirroring PI_SESSIONS_DIR's role) — not tart's
    # identity-namespaced spawn-side keys, which belong to tart's spawner.
    module Looplog
      DEFAULT_LIMIT = 2000
      WINDOW_DEFAULT = 900 # seconds: staleness threshold

      class << self
        # Inventory only: one line per transcript, mtime desc, no adoption.
        def list(space:, io: $stdout, env: ENV)
          Follower.new(space: space, io: io, env: env, replay: false, all: false, list_only: true).scan
        end

        # Follow active runs live; never returns on its own (Interrupt exits
        # quietly inside Follower#run).
        def follow(space:, io: $stdout, env: ENV, replay: false, all: false)
          Follower.new(space: space, io: io, env: env, replay: replay, all: all).run
        end
      end

      # Shared paint/oneline/discovery helpers, ported verbatim from the oracle
      # script. Color and the truncation budgets arrive per call (env/io), not
      # as load-time globals like the script's.
      module Support
        TAG_COLORS = %w[36 35 33 32 34 95 96 91].freeze

        private

        def paint(text, code)
          @color ? "\e[#{code}m#{text}\e[0m" : text
        end

        def dim(s)    = paint(s, "2")
        def bold(s)   = paint(s, "1")
        def cyan(s)   = paint(s, "36")
        def green(s)  = paint(s, "32")
        def red(s)    = paint(s, "31")

        # Collapses whitespace and clips, so a tool argument stays on one line.
        def oneline(value, limit)
          s = value.to_s.gsub(/\s+/, " ").strip
          s.length > limit ? "#{s[0, limit]}…" : s
        end

        def clip(text, limit = nil)
          return text if limit.nil? || text.length <= limit

          "#{text[0, limit]}…"
        end

        def sessions_root(env)
          env["PI_SESSIONS_DIR"] || File.join(Dir.home, ".pi", "agent", "sessions")
        end

        # pi names a session dir after the project root, dash-cased: the absolute
        # path's leading slash contributes one leading dash, pi adds one more, and a
        # trailing pair closes it (verified: …/20261009-pi-port → --Users-eric-
        # architect-spaces-20261009-pi-port--; /private/tmp/tart-bang-smoke →
        # --private-tmp-tart-bang-smoke--).
        def session_slug(path)
          "-#{path.tr('/', '-')}--"
        end

        # Two roots, deduped by path: pi's default sessions dir for the space slug
        # (agents spawned with cwd = the space) and the space's build/ tree (the
        # loop's headless --session-dir bootstraps root their whole transcript trees
        # there). Lane worktrees are the only huge subtrees under build/ — pruned.
        # [I95 B-Law 1] the tart roots append additively; the pi roots and their
        # scan law above are byte-stable. Dedup stays by transcript path.
        def discover(space, env)
          roots = [File.join(sessions_root(env), session_slug(space.to_s)), File.join(space.to_s, "build")]
                  .select { |root| File.directory?(root) }
                  .flat_map { |root| scan_root(root) }
          roots += scan_tart_runs(tart_subagents_home(env), space.to_s)
          roots += scan_tart_sessions(File.join(tart_sessions_root(env), session_slug(space.to_s)))
          roots.uniq { |t| t.path }
        end

        # The gem's reader-side overrides (B-Law 1) — PI_SESSIONS_DIR's role for
        # the tart roots. Deliberately NOT tart's identity-namespaced spawn-side
        # keys: reading another harness's spawn env would couple the reader to
        # its spawner law.
        def tart_subagents_home(env)
          env["TART_SUBAGENTS_HOME"] || File.join(Dir.home, ".tart", "subagents")
        end

        def tart_sessions_root(env)
          env["TART_SESSIONS_DIR"] || File.join(Dir.home, ".tart", "sessions")
        end

        # [I95 B-Law 2] the run-record law: each <home>/<run-id>/ dir whose
        # status.json parses is a run; it is IN SCOPE iff its spawn cwd is the
        # space or under it (lane worktrees stay in scope and keep the tag_label
        # lane-tag law via their recorded cwd). The transcript — the unit, pi-side
        # parity — is the NEWEST <run>/sessions/**/*.jsonl; a run with no
        # transcript is not listed. Malformed status.json or missing identity keys
        # skip silently (discovery never raises — the pi-side discipline). The
        # consumed keys are cwd + agent (both Strings across the real corpus; id
        # falls back to the dir name); task may be null in real status.json files
        # (measured: run 01a14df7-7750… carries task:null AND a real transcript),
        # so a null/absent task tolerates to nil rather than erasing the run.
        def scan_tart_runs(home, space)
          return [] unless File.directory?(home)

          Dir.children(home).filter_map do |entry| # paths:exempt — walks the tart subagents home's run dirs; per-run status.json discovery IS this module's contract (B-Law 2), mirroring scan_root's pi walk
            run_dir = File.join(home, entry)
            next unless File.directory?(run_dir)

            status = tart_status(run_dir)
            next unless status
            next unless tart_in_space?(status["cwd"], space)

            transcript, st = tart_newest_transcript(run_dir)
            next unless transcript

            run_id = status["id"].is_a?(String) ? status["id"] : entry
            Transcript.new(transcript, run_id, status["agent"], st.mtime.to_f, st.size,
                           status["cwd"], tart_task_line(status["task"]))
          end
        end

        # [I95 B-Law 3] the session-record law: every *.jsonl under the tart slug
        # dir (any depth, wt/ pruned as today) is a transcript with the gem's own
        # agent-less label (LoopCost::SESSION_AGENT — no invented labels, no mode
        # detection). Identity rides the line-1 session header (id, cwd); the
        # task is the first user-message entry's first line. Malformed/empty
        # files skip silently.
        def scan_tart_sessions(slug_dir)
          return [] unless File.directory?(slug_dir)

          Find.find(slug_dir).filter_map do |p| # paths:exempt — any-depth discovery of the tart slug dir IS this module's contract (mirrors scan_root's pi walk)
            if File.directory?(p)
              Find.prune if File.basename(p) == "wt"
              next
            end
            next unless p.end_with?(".jsonl")

            header = tart_session_header(p)
            next unless header

            st = File.stat(p)
            Transcript.new(p, header["id"], LoopCost::SESSION_AGENT, st.mtime.to_f, st.size,
                           header["cwd"], tart_first_user_task(p))
          end
        end

        def tart_status(run_dir)
          status = JSON.parse(File.read(File.join(run_dir, "status.json")))
          return unless status.is_a?(Hash) && status["cwd"].is_a?(String) && status["agent"].is_a?(String)

          status
        rescue JSON::ParserError, SystemCallError
          nil
        end

        # The run's spawn cwd is the space or under it (B-Law 2) — expand BOTH
        # sides, so a cwd or space spelled through a symlink (macOS /tmp →
        # /private/tmp) still scopes correctly.
        def tart_in_space?(cwd, space)
          expanded = File.expand_path(cwd)
          root = File.expand_path(space)
          expanded == root || expanded.start_with?("#{root}/")
        end

        def tart_newest_transcript(run_dir)
          Dir.glob(File.join(run_dir, "sessions", "**", "*.jsonl")) # paths:exempt — the NEWEST <run>/sessions/**/*.jsonl IS the transcript unit (B-Law 2); the recursive glob stays inside the run's own session tree
             .filter_map do |p|
               begin
                 st = File.stat(p)
                 st.file? ? [p, st] : nil
               rescue SystemCallError
                 nil
               end
             end
             .max_by { |_, st| st.mtime }
        end

        def tart_session_header(path)
          line = File.foreach(path).first
          return unless line&.start_with?("{")

          header = JSON.parse(line)
          return unless header.is_a?(Hash) && header["type"] == "session" &&
                        header["id"].is_a?(String) && header["cwd"].is_a?(String)

          header
        rescue JSON::ParserError, SystemCallError
          nil
        end

        # Head-bounded like backscan's 64 KB window: the first user message sits
        # at the head of real transcripts, and the bound keeps a feral file from
        # stalling discovery.
        def tart_first_user_task(path)
          read = 0
          File.open(path, "rb") do |f|
            f.each_line do |line|
              return nil if read > 64 * 1024

              read += line.bytesize
              next unless line.start_with?("{")

              rec = begin
                JSON.parse(line)
              rescue JSON::ParserError
                next
              end
              msg = rec["message"]
              next unless rec["type"] == "message" && msg.is_a?(Hash) && msg["role"] == "user"

              return tart_task_line(msg["content"].is_a?(String) ? msg["content"] : nil)
            end
          end
          nil
        rescue SystemCallError
          nil
        end

        # The pi-side task clip law: first line, chomped, 110 (note_record's clip,
        # applied to tart identities).
        def tart_task_line(text)
          return nil unless text.is_a?(String)

          text.lines.first.to_s.chomp[0, 110]
        end

        def scan_root(root)
          Find.find(root).filter_map do |p| # paths:exempt — walks the foreign pi sessions corpus and the space's build/ tree (nested session dirs included); any-depth discovery of *_transcript.jsonl IS this module's contract, mirroring the bin/looplog oracle
            if File.directory?(p)
              Find.prune if File.basename(p) == "wt"
              next
            end
            next unless p.end_with?("_transcript.jsonl")

            base = File.basename(p, ".jsonl").delete_suffix("_transcript")
            run_id, agent = base.split("_", 2)
            next unless run_id && agent

            st = File.stat(p)
            Transcript.new(p, run_id, agent, st.mtime.to_f, st.size, nil, nil)
          end
        end

        # Bounded backscan for the newest "Task:" user record and the live cwd —
        # every record carries cwd, so the file's tail suffices; the Task: record
        # lives at the head, so a tail miss falls back to the first 64 KB.
        def backscan(path)
          tail = []
          File.open(path, "rb") do |f|
            f.seek(0, IO::SEEK_END)
            window = [f.tell, 64 * 1024].min
            f.seek(-window, IO::SEEK_END)
            f.each_line { |l| tail << l }
          end
          head = []
          File.open(path, "rb") do |f|
            f.each_line { |l| head << l; break if head.sum(&:bytesize) > 64 * 1024 }
          end
          task = nil
          cwd = nil
          tail.reverse_each { |l| cwd, task = note_record(l, cwd, task) }
          head.reverse_each { |l| cwd, task = note_record(l, cwd, task) }
          [cwd, task]
        end

        def note_record(line, cwd, task)
          return [cwd, task] unless line.start_with?("{") && (cwd.nil? || task.nil?)

          rec = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          return [cwd, task] unless rec

          cwd ||= rec["cwd"]
          if task.nil? && rec["recordType"] == "message" && rec["role"] == "user" &&
             rec["text"].to_s.start_with?("Task:")
            task = rec["text"].lines.first.chomp[0, 110]
          end
          [cwd, task]
        end

        # [I95 B-Law 4] the tart-record adapter: projects one tart session entry
        # onto the pi record vocabulary so the ONE Renderer keeps the display
        # law, the stamps, and the ✓/✗ lines — shared, not forked. Pi records
        # (recordType-carriers) and foreign shapes pass through untouched, so
        # the pi drain path is byte-stable. The tart vocabulary, measured over
        # the real corpus: {type: session|message|custom_message}; message
        # entries carry {role: user|assistant|tool, content: String} with
        # assistant extras tool_calls (a Hash keyed by call id, values
        # {id, name, arguments: Hash}), thinking (String), flat usage keys, and
        # finish_reason ∈ tool_calls|stop|length|error.
        def adapt_record(rec)
          return [rec] unless rec.is_a?(Hash) && rec["recordType"].nil?

          case rec["type"]
          when "session"        then []   # header record: identity, not display
          when "custom_message" then []   # wake/notify echoes: pi's system/custom law
          when "message"        then tart_message_records(rec)
          else [rec]                      # foreign vocabulary: the renderer's else-arm
          end
        end

        def tart_message_records(rec)
          msg = rec["message"]
          return [] unless msg.is_a?(Hash)

          ts = tart_ts(rec)
          case msg["role"]
          when "user"
            # The exchange opener: no display of its own, exactly like pi's.
            [{ "recordType" => "message", "role" => "user", "ts" => ts }]
          when "assistant"
            [tart_assistant_record(msg, ts)] + tart_tool_starts(msg, ts)
          when "tool"
            # Tart records carry no error flag — isError false (the ✗ arm stays
            # pi-only; a tart error surfaces through finish_reason instead).
            [{ "recordType" => "message", "role" => "toolResult", "text" => msg["content"].to_s,
               "isError" => false, "ts" => ts }]
          else # legacy/system roles (bashExecution, …): everything of interest shows elsewhere
            []
          end
        end

        # Block order is the shared display law's order (thinking dim, then the
        # text, then the tool calls) — the real chronology of one assistant turn.
        def tart_assistant_record(msg, ts)
          blocks = []
          thinking = msg["thinking"]
          blocks << { "type" => "thinking", "thinking" => thinking } if thinking.is_a?(String) && !thinking.empty?
          content = msg["content"]
          blocks << { "type" => "text", "text" => content } if content.is_a?(String) && !content.empty?
          tart_tool_calls(msg).each do |call|
            blocks << { "type" => "toolCall", "id" => call["id"], "name" => call["name"],
                        "arguments" => call["arguments"] }
          end
          {
            "recordType" => "message", "role" => "assistant", "ts" => ts,
            "stopReason" => tart_stop_reason(msg["finish_reason"]),
            # Usage maps output_tokens→output, cache_write_tokens→the cache slot
            # (B-Law 4); tart's cache_read_tokens is deliberately NOT mapped —
            # no fabricated numbers. Cost is never fabricated.
            "usage" => { "output" => msg["output_tokens"], "cacheRead" => msg["cache_write_tokens"] },
            "message" => { "content" => blocks }
          }
        end

        # tool_calls is a Hash keyed by call id across the real corpus (597/597);
        # an Array of entries is tolerated defensively, anything else is absence.
        def tart_tool_calls(msg)
          calls = msg["tool_calls"]
          entries = calls.is_a?(Hash) ? calls.each_value : calls.is_a?(Array) ? calls : []
          entries.select { |call| call.is_a?(Hash) && call["name"] }
        end

        # The harness re-emits canonical args on tool_start in pi — the adapter
        # synthesizes that record here, so the one-lined ⚒ law renders exactly
        # as pi's (arguments are JSON-roundtripped values, so generate is safe).
        def tart_tool_starts(msg, ts)
          tart_tool_calls(msg).map do |call|
            { "recordType" => "tool_start", "toolName" => call["name"].to_s,
              "argsPayload" => JSON.generate(call["arguments"]), "ts" => ts }
          end
        end

        # finish_reason → pi stopReason vocabulary (B-Law 4): the two shared
        # semantics map, everything else — length, error, nil — passes verbatim
        # ("error" keys the shared ✗ failed arm; "length" still closes with ✓).
        def tart_stop_reason(finish_reason)
          case finish_reason
          when "tool_calls" then "toolUse"
          when "stop"       then "end_turn"
          else finish_reason
          end
        end

        # The entry timestamp (ISO) carries the record stamp law unchanged, as
        # epoch-ms so the shared exchange arithmetic (elapsed) works unchanged.
        def tart_ts(rec)
          return unless rec["timestamp"].is_a?(String)

          Time.parse(rec["timestamp"]).to_f * 1000
        rescue ArgumentError
          nil
        end

        # [architect-builder:67-core] when cwd is a lane worktree — the full
        # agent name plus the iteration ordinal and the lane name, resolved
        # against the space's known iteration ids (architecture/I<NN>-<name>.md)
        # so a hyphenated iteration slug cannot bleed into the lane
        # (I06-editor-markdown-markdown-seam → 06-markdown-seam). The agent name
        # is shown verbatim — no abbrev map (forwards-compatible with new
        # roles). An unrecognized dir (no architecture/, or a legacy name)
        # falls back to the whole dir name minus the I<NN>- prefix, clipped.
        def tag_label(agent, cwd, iteration_ids: [])
          return agent unless cwd && File.basename(cwd) == "wt"

          dir = File.basename(File.dirname(cwd))
          ordinal = dir[/\A[Ii](\d+)-/, 1]
          return "#{agent}:#{dir[0, 26]}" unless ordinal

          lane = iteration_ids.filter_map { |id| dir.delete_prefix("#{id}-") if dir.start_with?("#{id}-") }.first
          lane ||= dir.sub(/\A[Ii]\d+-/, "")
          "#{agent}:#{ordinal}-#{lane[0, 26]}"
        end

        def paint_tag(label, run_id)
          code = TAG_COLORS[run_id.sum % TAG_COLORS.size]
          paint("[#{label}]", code)
        end
      end

      Transcript = Data.define(:path, :run_id, :agent, :mtime, :size, :cwd, :task)

      # Adapts runlog's Printer to whole-message transcript records; emits fully
      # painted lines (the follower prefixes the per-run tag). Ported verbatim.
      class Renderer
        include Support

        def initialize(limit:, think_limit:, color:)
          @limit = limit
          @think_limit = think_limit
          @color = color
          @exchange = nil # usage accumulated across the rounds of an exchange
        end

        def render(rec)
          case rec["recordType"]
          when "tool_start" then [tool_call(rec)]
          when "tool_end"   then [] # the result rides the toolResult message
          when "message"    then message(rec)
          else []
          end
        end

        private

        def message(rec)
          case rec["role"]
          when "assistant" then assistant(rec)
          when "toolResult" then [tool_result(rec)]
          when "user"
            # A user message opens an exchange; every assistant round that follows
            # belongs to it, up through the final (non-toolUse) stop.
            @exchange = { started_at: rec["ts"], output: 0, cache_read: 0, cost: 0.0 }
            []
          else # system/custom echoes: everything of interest shows elsewhere
            []
          end
        end

        def assistant(rec)
          lines = []
          (rec.dig("message", "content") || []).each do |block|
            case block["type"]
            when "thinking"
              text = clip(block["thinking"].to_s, @think_limit)
              next if text.empty?

              lines << dim("· thinking")
              text.lines.each { |l| lines << dim(l.chomp) }
            when "text"
              text = block["text"].to_s
              next if text.empty?

              lines << bold("● assistant")
              text.lines.each { |l| lines << l.chomp }
            end
            # toolCall blocks: the harness re-emits canonical args on tool_start,
            # which is what we display — one source, reflecting what actually ran.
          end
          lines << usage_line(rec) if final_stop?(rec)
          lines
        end

        def final_stop?(rec)
          reason = rec["stopReason"]
          reason && reason != "toolUse"
        end

        def usage_line(rec)
          u = rec["usage"] || {}
          ex = @exchange
          output = (ex ? ex[:output] : 0) + u["output"].to_i
          cache = (ex ? ex[:cache_read] : 0) + u["cacheRead"].to_i
          # cost is nested ({total: …}) in run.jsonl-shaped events but a plain
          # Float in the artifact transcripts — accept both.
          cost_value = u["cost"]
          cost_value = cost_value["total"] if cost_value.is_a?(Hash)
          cost = (ex ? ex[:cost] : 0.0) + cost_value.to_f
          started = ex ? ex[:started_at] : nil
          @exchange = nil
          elapsed = started && rec["ts"] ? (rec["ts"] - started) / 1000 : nil
          stats = [
            "#{output} out",
            "#{cache} cache read",
            ("$#{format('%.2f', cost)}" if cost.positive?),
            ("#{format('%.0f', elapsed)}s" if elapsed)
          ].compact.join("  ")
          failed = rec["stopReason"].to_s.casecmp("error").zero?
          (failed ? red("✗ failed") : green("✓ done")) + dim("  #{stats}")
        end

        def tool_call(rec)
          args = begin
            JSON.parse(rec["argsPayload"] || "")
          rescue JSON::ParserError, TypeError
            nil
          end
          summary = if args.is_a?(Hash)
                      args.map { |k, v| "#{k}: #{oneline(v, @limit)}" }.join("  ")
                    else
                      oneline(rec["argsPreview"], @limit)
                    end
          "#{cyan("⚒ #{rec['toolName']}")} #{dim(summary)}"
        end

        def tool_result(rec)
          body = rec["text"].to_s
          note = body.lines.size > 1 ? dim(" (#{body.lines.size} lines)") : ""
          marker = rec["isError"] ? red("✗") : green("←")
          "#{marker} #{oneline(body, @limit)}#{note}"
        end
      end

      # Scans for transcripts, adopts the fresh ones, and drains their appended
      # bytes — the follow loop's engine, ported verbatim.
      class Follower
        include Support

        POLL = 0.5
        RESCAN = 2.0

        Run = Struct.new(:path, :run_id, :agent, :tag, :renderer, :offset, :partial, :stamp)

        attr_reader :runs

        def initialize(space:, io:, env:, replay:, all:, list_only: false)
          @space = space
          @io = io
          @env = env
          @limit = (env["RUNLOG_LIMIT"] || DEFAULT_LIMIT).to_i
          @window = (env["LOOPLOG_WINDOW"] || WINDOW_DEFAULT).to_i
          @replay = replay
          @all = all
          @list_only = list_only
          @color = io.tty? && env["NO_COLOR"].nil?
          @runs = {}
        end

        def run
          scan
          return if @list_only

          last_scan = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          loop do
            sleep POLL
            @runs.each_value { |r| drain(r) }
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if now - last_scan >= RESCAN
              scan
              last_scan = now
            end
          end
        rescue Interrupt
          # ctrl+c while following: exit quietly with the output already on screen.
        end

        # The incremental seams the tests exercise: scan adopts fresh transcripts
        # (or prints the inventory when list-only), drain consumes newly appended
        # bytes. Public on purpose — tests drive these directly instead of the
        # never-ending follow loop.
        def scan
          now = Time.now.to_f
          if @list_only
            discover(@space, @env).sort_by { |t| -t.mtime }.each do |t|
              age_min = (now - t.mtime) / 60
              active = (now - t.mtime) < @window
              cwd, task = record_meta(t)
              @io.puts format("%s %-9s %5s %5.0fm %7sK  %s  %s",
                              active ? green("●") : dim("·"),
                              tag_label(t.agent, cwd, iteration_ids: iteration_ids),
                              dim(Time.at(t.mtime).strftime("%H:%M")),
                              age_min, t.size / 1024,
                              dim(t.run_id[0, 8]),
                              dim(task.to_s[0, 70]))
            end
            return
          end
          discover(@space, @env).each do |t|
            next if @runs.key?(t.path)
            next unless @all || (now - t.mtime) < @window

            adopt(t)
          end
        end

        def drain(run)
          return unless File.exist?(run.path) && File.size(run.path) > run.offset

          File.open(run.path, "rb") do |f|
            f.seek(run.offset)
            run.partial << f.read
            run.offset = f.tell
          end
          while (idx = run.partial.index("\n"))
            line = run.partial.slice!(0..idx)
            next unless line.start_with?("{")

            rec = begin
              JSON.parse(line)
            rescue JSON::ParserError
              next
            end
            # [I95 B-Law 4] one tart entry projects to several records (the
            # message plus its synthesized tool starts); all share the entry's
            # stamp, taken from the projected record so the epoch-ms arm of the
            # unchanged stamp law renders tart rows local exactly like pi rows.
            # Pi lines pass through as the single-element array — same bytes.
            projected = adapt_record(rec)
            run.stamp = stamp_for(projected.first || rec)
            projected.each { |pi_rec| emit(run, run.renderer.render(pi_rec)) }
          end
        end

        private

        # The space's iteration ids (architecture/I<NN>-<name>.md basenames) —
        # the authority for splitting a lane dir name into iteration and lane
        # without guessing at hyphen boundaries.
        def iteration_ids
          # paths:exempt — the I[0-9]*-*.md pattern structurally cannot match a dotfile-prefixed name; one non-hidden directory level, no dotfile hazard
          @iteration_ids ||= Dir.glob(File.join(@space.to_s, "architecture", "I[0-9]*-*.md"))
                               .map { |p| File.basename(p, ".md") }
        end

        # [I95 B-Laws 2–3] tart transcripts carry identity on the record itself
        # (the run's status.json / the session header); pi transcripts are
        # backscanned. A nil tart slot falls through to the backscan, so a
        # headerless tart file still shows a derived cwd.
        def record_meta(t)
          cwd, task = backscan(t.path)
          [t.cwd || cwd, t.task || task]
        end

        def adopt(t)
          cwd, task = record_meta(t)
          tag = paint_tag(tag_label(t.agent, cwd, iteration_ids: iteration_ids), t.run_id)
          run = Run.new(t.path, t.run_id, t.agent, tag,
                        Renderer.new(limit: @limit, think_limit: @env["RUNLOG_THINK"]&.to_i, color: @color),
                        @replay ? 0 : t.size, +"", stamp_now)
          @runs[t.path] = run
          emit(run, [bold("▶ #{t.agent} #{t.run_id[0, 8]}") +
                     (cwd ? dim("  @ #{cwd.sub(Dir.home, '~')}") : "") +
                     (task ? dim(" — #{task}") : "")])
        end

        def emit(run, lines)
          stamp = run.stamp ? "#{dim(run.stamp)} " : ""
          lines.each { |l| @io.puts "#{run.tag} #{stamp}#{l}" unless l.nil? || l.empty? }
          @io.flush
        end

        def stamp_now = Time.now.strftime("%H:%M:%S")

        # Records carry epoch-ms +"ts" and an ISO +"timestamp+" (UTC); display local.
        def stamp_for(rec)
          t = if rec["ts"].is_a?(Numeric)
                Time.at(rec["ts"] / 1000.0)
              elsif (iso = rec["timestamp"])
                Time.parse(iso) rescue nil
              end
          t&.strftime("%H:%M:%S")
        end
      end
    end
  end
end

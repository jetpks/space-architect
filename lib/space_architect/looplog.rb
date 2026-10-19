# frozen_string_literal: true

require "json"
require "time"
require "find"

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
        def discover(space, env)
          roots = [File.join(sessions_root(env), session_slug(space.to_s)), File.join(space.to_s, "build")]
                  .select { |root| File.directory?(root) }
                  .flat_map { |root| scan_root(root) }
          roots.uniq { |t| t.path }
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
              cwd, task = backscan(t.path)
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
            run.stamp = stamp_for(rec)
            emit(run, run.renderer.render(rec))
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

        def adopt(t)
          cwd, task = backscan(t.path)
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

# frozen_string_literal: true

require "json"
require "time"
require "find"
require "open3"
require_relative "harness"

module Space::Architect
  # `architect cost` aggregation — the read-only accounting of the loop's spend
  # and speed from the pi session artifacts already on disk. Pure module in the
  # routing.rb house shape: no CLI or terminal dependencies, plain class
  # methods, Space::Core::Error naming paths on failure. The corpus is the slug
  # dir under the pi sessions root (`--` + space path with `/` → `-` + `--`);
  # three artifact shapes are folded into one model: run metas (`*_meta.json`,
  # any depth), session files (any other `*.jsonl` whose first line is a
  # `type: "session"` header — interactive and runner files), and run
  # transcripts (`*_transcript.jsonl`, latency rounds only — their per-message
  # cost belongs to the meta's total, so counting both would double-count).
  # Everything skips malformed files/lines instead of crashing: the sums
  # reflect what parsed. Model identity is normalized to one bare key per
  # model — runs by requestedModel (falling back to model) with a trailing
  # `:level` thinking suffix stripped via Harness.parse_model_suffix, session
  # messages by provider/model — so no row key ever carries a suffix.
  module LoopCost
    # The agent label for session-file rows; a session file carries no agent
    # identity, and only assistant messages carry usage, so the two artifact
    # kinds never double-count each other.
    SESSION_AGENT = "(session)"

    class << self
      # The pi sessions dir for a space: the space's absolute path with every
      # `/` turned into `-`, wrapped in dashes — the trailing `/` is slugified
      # too, which is why live dirs carry TWO leading and TWO trailing dashes
      # (`/Users/eric` → `--Users-eric--`). Verified against every dir in the
      # live sessions root; the frozen cost-readonly gate's fixture dir name
      # (`--Users-eric-architect-spaces-20261009-pi-port--`) pins the same
      # shape. (The spec's one-line `-` + tr + `-` formula omits the trailing
      # separator and names a dir that does not exist.)
      def slug_dir(space_path)
        "-" + "#{space_path}/".tr("/", "-") + "-"
      end

      # `--since` intake: ISO-8601 timestamps, or a bare `YYYY-MM-DD` date —
      # local midnight of that calendar day, since a date with no zone means
      # the local day. Any other shape is user error, raised loud.
      def parse_since(value)
        return nil if value.nil? || value.strip.empty?

        text = value.strip
        if (m = text.match(/\A(\d{4})-(\d{2})-(\d{2})\z/))
          return Time.new(m[1].to_i, m[2].to_i, m[3].to_i)
        end
        return Time.iso8601(text) if iso8601?(text)

        raise Space::Core::Error,
          "--since '#{value}' is not an ISO-8601 timestamp or YYYY-MM-DD date"
      end

      # The whole report: the frozen `--json` contract shape (plus `iterations`
      # / `grand_total` for --by-iteration and `latency` for --latency). The
      # text views render from this same hash, so text and JSON can never
      # disagree on the numbers.
      def report(space:, sessions_root:, since: nil, by_iteration: false, latency: false)
        root = File.expand_path(sessions_root.to_s)
        slug = slug_dir(space.path)
        slug_path = File.join(root, slug)
        unless File.directory?(slug_path)
          raise Space::Core::Error,
            "no sessions dir for space #{space.id} — expected #{slug_path} (sessions root #{root})"
        end

        floor = parse_since(since)
        corpus = load_corpus(slug_path: slug_path, floor: floor, with_transcripts: latency)
        rows, totals = aggregate(corpus[:runs], corpus[:sessions])

        report = {
          "space" => space.id,
          "slug_dir" => slug,
          "sessions_root" => root,
          "since" => since,
          "runs" => corpus[:runs].size,
          "sessions" => corpus[:sessions].size,
          "rows" => rows,
          "totals" => totals
        }
        if by_iteration
          buckets = iteration_buckets(corpus[:runs], corpus[:sessions], space)
          report["iterations"] = buckets
          # The buckets partition the filtered corpus exactly, so the grand
          # total IS the corpus total — one accumulation, no re-summing drift.
          report["grand_total"] = report["totals"]
        end
        report["latency"] = latency_rows(corpus[:rounds]) if latency
        report
      end

      # Iteration boundaries, in ordinal order: git commit time of freeze_sha
      # in the space repo (authoritative — it exists even when the rehearsal
      # clock drifted), falling back to rehearsal.at, then the earliest
      # dispatched_at. An iteration with none of the three is unusable and
      # yields no window; its span simply merges into the preceding one.
      def iteration_boundaries(space)
        project = space.data["project"].is_a?(Hash) ? space.data["project"] : {}
        entries = project["iterations"].is_a?(Array) ? project["iterations"] : []
        entries.sort_by { |e| e.is_a?(Hash) ? e["ordinal"].to_i : 0 }.filter_map do |entry|
          next unless entry.is_a?(Hash)

          at = boundary_time(entry, space.path)
          at && { name: entry["name"].to_s, at: at }
        end
      end

      private

      def iso8601?(text)
        Time.iso8601(text)
        true
      rescue ArgumentError
        false
      end

      def safe_iso(value)
        Time.iso8601(value) if value.is_a?(String)
      rescue ArgumentError
        nil
      end

      def within_floor?(start, floor)
        floor.nil? || start >= floor
      end

      def numeric(value)
        value.is_a?(Numeric) ? value : 0
      end

      # One malformed line drops only itself — a truncated tail is just the
      # last partial line failing to parse — never the records around it.
      def parse_line(line)
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      # Session costs arrive as a Hash `{total: …}`; metas carry a plain
      # number. Both accepted, anything else counts as zero.
      def cost_of(usage)
        cost = usage["cost"]
        return cost["total"].to_f if cost.is_a?(Hash) && cost["total"].is_a?(Numeric)
        return cost.to_f if cost.is_a?(Numeric)

        0.0
      end

      # One bare key per model: the trailing `:level` thinking suffix appears
      # on metas' requestedModel AND model, and on session models — strip it
      # everywhere so `zai/glm-5.3-flash:high` folds into `zai/glm-5.3-flash`.
      def normalize_model(ref)
        return nil unless ref.is_a?(String) && !ref.strip.empty?

        Harness.parse_model_suffix(ref.strip)[0]
      end

      def epoch_ms(value)
        Time.at(value / 1000.0) if value.is_a?(Numeric)
      end

      def new_usage
        { input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0 }
      end

      def new_cell
        new_usage.merge(runs: 0, turns: 0)
      end

      def add_usage!(cell, usage)
        cell[:input] += usage[:input]
        cell[:output] += usage[:output]
        cell[:cache_read] += usage[:cache_read]
        cell[:cache_write] += usage[:cache_write]
        cell[:cost] += usage[:cost]
      end

      # ---- discovery -------------------------------------------------------

      def load_corpus(slug_path:, floor:, with_transcripts:)
        runs = []
        sessions = []
        transcript_files = []
        Find.find(slug_path) do |path| # paths:exempt — walks the foreign pi sessions corpus (a slug dir, not the space's own tree); any-depth discovery of *_meta.json and .jsonl session files IS this module's contract
          next unless File.file?(path)
          if path.end_with?("_meta.json")
            run = read_run(path)
            runs << run if run && within_floor?(run[:start], floor)
          elsif path.end_with?(".jsonl")
            header = read_session_header(path)
            if header
              session = read_session(path, header)
              sessions << session if session && within_floor?(session[:start], floor)
            elsif with_transcripts && path.end_with?("_transcript.jsonl")
              transcript_files << path
            end
          end
        end

        corpus = { runs: runs, sessions: sessions, rounds: [] }
        # Session rounds ride into the latency corpus as per-model tuples (the
        # walker already folds a file's rounds per key); transcripts append
        # below. Both shapes share the corpus — one round definition.
        sessions.each do |session|
          session[:rounds].each do |model, cell|
            corpus[:rounds] <<
              { model: model, rounds: cell[:count], wall_s: cell[:wall_s], output_tokens: cell[:output_tokens] }
          end
        end
        return corpus unless with_transcripts

        # Join runs by runId from the ALREADY-filtered list: a run dropped by
        # --since must not have its transcript leak back in through the join.
        runs_by_id = runs.filter_map { |r| r[:run_id] && [r[:run_id], r] }.to_h
        transcript_files.each do |path|
          artifact = read_transcript(path, runs_by_id)
          next unless artifact && within_floor?(artifact[:start], floor)

          corpus[:rounds].concat(artifact[:rounds])
        end
        corpus
      end

      # A meta unusable for row attribution (unparseable, no agent, no model
      # key, no usage, no timestamp) drops out of the sums entirely — there is
      # no row it could land in. The live corpus always carries all of these.
      def read_run(path)
        meta = JSON.parse(File.read(path))
        return nil unless meta.is_a?(Hash)

        usage = meta["usage"].is_a?(Hash) ? meta["usage"] : nil
        agent = meta["agent"]
        model = normalize_model(meta["requestedModel"] || meta["model"])
        start = epoch_ms(meta["timestamp"])
        return nil unless usage && agent.is_a?(String) && !agent.empty? && model && start

        {
          agent: agent,
          model: model,
          run_id: meta["runId"],
          start: start,
          input: numeric(usage["input"]),
          output: numeric(usage["output"]),
          cache_read: numeric(usage["cacheRead"]),
          cache_write: numeric(usage["cacheWrite"]),
          cost: cost_of(usage),
          turns: numeric(usage["turns"])
        }
      rescue JSON::ParserError, Errno::ENOENT, Errno::EISDIR
        nil
      end

      # A session file IS any .jsonl whose first line is a type:session header
      # — the check is structural, so transcripts and noise files are excluded
      # by shape, never by name.
      def read_session_header(path)
        File.open(path) do |file|
          line = file.gets
          header = line && JSON.parse(line)
          header.is_a?(Hash) && header["type"] == "session" ? header : nil
        end
      rescue JSON::ParserError, Errno::ENOENT, Errno::EISDIR
        nil
      end

      def read_session(path, header)
        start = safe_iso(header["timestamp"])
        return nil unless start

        usage = {}
        rounds = {}
        open_round = nil
        File.foreach(path) do |line|
          record = parse_line(line)
          next unless record
          message = record["message"]
          next unless message.is_a?(Hash)

          role = message["role"]
          ts = safe_iso(record["timestamp"]) || safe_iso(message["timestamp"])
          if role == "user"
            close_round!(rounds, open_round) if open_round
            # A user record without a timestamp cannot anchor a wall time —
            # the round would be unmeasurable, so it opens nothing.
            open_round = ts ? { user_ts: ts, wall_s: 0.0, output_tokens: 0, model: nil } : nil
          elsif role == "assistant"
            message_usage = message["usage"].is_a?(Hash) ? message["usage"] : nil
            model = session_model_key(message)
            if message_usage && model
              cell = (usage[model] ||= new_usage)
              cell[:input] += numeric(message_usage["input"])
              cell[:output] += numeric(message_usage["output"])
              cell[:cache_read] += numeric(message_usage["cacheRead"])
              cell[:cache_write] += numeric(message_usage["cacheWrite"])
              cell[:cost] += cost_of(message_usage)
            end
            if open_round && ts
              open_round[:wall_s] = [ts - open_round[:user_ts], 0.0].max
              open_round[:output_tokens] += numeric(message_usage["output"]) if message_usage
              open_round[:model] = model if model
            end
          end
        end
        close_round!(rounds, open_round) if open_round
        { start: start, usage: usage, rounds: rounds }
      rescue Errno::ENOENT
        # The file vanished mid-read: the round still closes and everything
        # parsed so far stays in the sums.
        close_round!(rounds, open_round) if open_round
        { start: start, usage: usage, rounds: rounds }
      end

      def session_model_key(message)
        provider = message["provider"]
        model = message["model"]
        return nil unless provider.is_a?(String) && !provider.empty? && model.is_a?(String) && !model.empty?

        normalize_model("#{provider}/#{model}")
      end

      def close_round!(rounds, round)
        return unless round[:model]

        cell = (rounds[round[:model]] ||= { count: 0, wall_s: 0.0, output_tokens: 0 })
        cell[:count] += 1
        cell[:wall_s] += round[:wall_s]
        cell[:output_tokens] += round[:output_tokens]
      end

      # Same round state machine as read_session: user opens, the last
      # assistant before the next user (or EOF) closes. A transcript maps to
      # its run meta via runId for the model key — its own record model ids
      # are provider-scoped and NOT stable keys — falling back to the record's
      # own model when no meta resolves (orphan transcripts exist in the wild).
      def read_transcript(path, runs_by_id)
        rounds = []
        open_round = nil
        run_ids = []
        first_ts = nil
        File.foreach(path) do |line|
          record = parse_line(line)
          next unless record.is_a?(Hash) && record["recordType"] == "message"

          run_ids << record["runId"] if record["runId"].is_a?(String)
          first_ts ||= record_time(record)
          role = record["role"] || (record["message"].is_a?(Hash) && record["message"]["role"])
          ts = record_time(record)
          if role == "user"
            close_transcript_round!(rounds, open_round) if open_round
            # No timestamp → no wall to measure; the round opens nothing.
            open_round = ts ? { user_ts: ts, wall_s: 0.0, output_tokens: 0, model: nil } : nil
          elsif role == "assistant" && ts && open_round
            usage = record["usage"].is_a?(Hash) ? record["usage"] : nil
            open_round[:wall_s] = [ts - open_round[:user_ts], 0.0].max
            open_round[:output_tokens] += numeric(usage["output"]) if usage
            model = joined_model(record, runs_by_id) || normalize_model(record["model"])
            open_round[:model] = model if model
          end
        end
        close_transcript_round!(rounds, open_round) if open_round
        return nil unless first_ts

        meta = run_ids.uniq.size == 1 ? runs_by_id[run_ids.first] : nil
        { start: meta ? meta[:start] : first_ts, rounds: rounds }
      rescue Errno::ENOENT
        # The file vanished mid-read: the round still closes; rounds parsed
        # so far count.
        close_transcript_round!(rounds, open_round) if open_round
        return nil unless first_ts

        { start: first_ts, rounds: rounds }
      end

      def record_time(record)
        epoch_ms(record["ts"]) || safe_iso(record["timestamp"])
      end

      def joined_model(record, runs_by_id)
        return nil unless record["runId"].is_a?(String)

        runs_by_id[record["runId"]]&.fetch(:model, nil)
      end

      def close_transcript_round!(rounds, round)
        return unless round[:model]

        rounds << { model: round[:model], rounds: 1, wall_s: round[:wall_s], output_tokens: round[:output_tokens] }
      end

      # ---- aggregation -----------------------------------------------------

      # Rows keyed agent × model: runs by their meta's agent, session files by
      # the literal (session) label. A session file's per-model row counts the
      # file once and takes its turns from the rounds attributed to that model.
      def aggregate(runs, sessions)
        cells = Hash.new { |hash, key| hash[key] = new_cell }
        runs.each do |run|
          cell = cells[[run[:agent], run[:model]]]
          cell[:runs] += 1
          add_usage!(cell, run)
          cell[:turns] += run[:turns]
        end
        sessions.each do |session|
          session[:usage].each do |model, session_usage|
            cell = cells[[SESSION_AGENT, model]]
            cell[:runs] += 1
            add_usage!(cell, session_usage)
            # Usage can exist without a measurable round (a leading assistant
            # message bills tokens, but no user message opened a round) — its
            # turns are simply the rounds that did parse, possibly 0.
            cell[:turns] += (session[:rounds][model] || {}).fetch(:count, 0)
          end
        end

        rows = cells.sort_by { |(agent, model), _| [agent, model] }.map do |(agent, model), cell|
          row(agent, model, cell)
        end
        totals_cell = cells.values.reduce(new_cell) do |sum, cell|
          sum[:runs] += cell[:runs]
          sum[:turns] += cell[:turns]
          add_usage!(sum, cell)
          sum
        end
        [rows, totals(totals_cell)]
      end

      def row(agent, model, cell)
        { "agent" => agent, "model" => model }.merge(totals(cell))
      end

      def totals(cell)
        {
          "runs" => cell[:runs],
          "input" => cell[:input],
          "output" => cell[:output],
          "cache_read" => cell[:cache_read],
          "cache_write" => cell[:cache_write],
          "cost" => cell[:cost],
          "turns" => cell[:turns],
          "cache_hit_ratio" => cache_hit_ratio(cell[:cache_read], cell[:input])
        }
      end

      def cache_hit_ratio(cache_read, input)
        denominator = input + cache_read
        denominator.positive? ? cache_read.fdiv(denominator) : 0.0
      end

      # ---- iteration buckets ----------------------------------------------

      def iteration_buckets(runs, sessions, space)
        bounds = iteration_boundaries(space)
        buckets = bounds.map do |bound|
          { name: bound[:name], starts_at: bound[:at], runs: [], sessions: [] }
        end
        unattributed = { name: "unattributed", starts_at: nil, runs: [], sessions: [] }
        runs.each do |run|
          bucket_for(run[:start], bounds, buckets, unattributed)[:runs] << run
        end
        sessions.each do |session|
          bucket_for(session[:start], bounds, buckets, unattributed)[:sessions] << session
        end

        (buckets + [unattributed]).map { |bucket| bucket_json(bucket) }
      end

      # Windows are [boundary_i, boundary_{i+1}) — the last one open-ended;
      # rindex over `>=` lands an artifact exactly on a boundary in the later
      # window. Before the first boundary (or no boundaries at all) is
      # "unattributed".
      def bucket_for(start, bounds, buckets, unattributed)
        index = bounds.rindex { |bound| start >= bound[:at] }
        index ? buckets[index] : unattributed
      end

      def bucket_json(bucket)
        rows, totals = aggregate(bucket[:runs], bucket[:sessions])
        {
          "name" => bucket[:name],
          "starts_at" => bucket[:starts_at]&.utc&.iso8601,
          "rows" => rows,
          "totals" => totals
        }
      end

      def boundary_time(entry, space_path)
        sha = entry["freeze_sha"]
        if sha.is_a?(String) && !sha.strip.empty?
          out, _, status = Open3.capture3("git", "-C", space_path.to_s, "show", "-s", "--format=%cI", sha.strip)
          committed = status.success? ? safe_iso(out.strip) : nil
          return committed if committed
        end

        rehearsal = entry["rehearsal"]
        at = rehearsal.is_a?(Hash) ? rehearsal["at"] : nil
        return safe_iso(at) if safe_iso(at)

        lanes = entry["lanes"].is_a?(Array) ? entry["lanes"] : []
        lanes.filter_map { |lane| lane.is_a?(Hash) ? safe_iso(lane["dispatched_at"]) : nil }.min
      end

      # ---- latency ---------------------------------------------------------

      # Rounds from run transcripts and session files share one shape; wall is
      # clamped at zero because a clock-skewed negative round would otherwise
      # drag the reported means below AC's non-negative floor.
      def latency_rows(rounds)
        cells = Hash.new { |hash, key| hash[key] = { rounds: 0, wall_s: 0.0, output_tokens: 0 } }
        rounds.each do |round|
          cell = cells[round[:model]]
          cell[:rounds] += round[:rounds]
          cell[:wall_s] += round[:wall_s]
          cell[:output_tokens] += round[:output_tokens]
        end
        cells.sort_by { |model, _| model }.map do |model, cell|
          {
            "model" => model,
            "rounds" => cell[:rounds],
            "wall_s" => cell[:wall_s],
            "mean_wall_s" => cell[:rounds].positive? ? cell[:wall_s] / cell[:rounds] : 0.0,
            "output_tokens" => cell[:output_tokens],
            "output_toks_per_s" => cell[:wall_s].positive? ? cell[:output_tokens] / cell[:wall_s] : 0.0
          }
        end
      end
    end
  end
end

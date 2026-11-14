# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/space_architect/looplog"
require "json"
require "stringio"

# The renderer golden is generated from the byte-compat oracle (the pi-port
# bin/looplog; load skips its __FILE__ entry guard):
#   NO_COLOR=1 ruby -e 'load "/Users/eric/architect/spaces/20261009-pi-port/bin/looplog"; \
#     r = Renderer.new; ARGF.each_line { |l| next unless l.start_with?("{"); \
#     r.render(JSON.parse(l)).each { |line| puts line } }' \
#     test/fixtures/looplog/records.jsonl > test/fixtures/looplog/render.expected
class LooplogTest < Space::ArchitectTest
  FIXTURES = File.join(__dir__, "fixtures", "looplog")

  # The renderer shapes covered by records.jsonl: thinking (dim, multi-line),
  # text, tool_start via parsed argsPayload and via argsPreview fallback,
  # toolResult ←/✗ with a line-count note, silent system/tool_end records, a
  # toolUse stop with no done line, and the final ✓ done with usage/cost/
  # elapsed from the exchange's user timestamp.
  def test_looplog_renders_transcript_records_from_the_oracle_golden
    renderer = Space::Architect::Looplog::Renderer.new(limit: 2000, think_limit: nil, color: false)
    lines = []
    File.foreach(File.join(FIXTURES, "records.jsonl")) do |raw|
      next unless raw.start_with?("{")

      lines.concat(renderer.render(JSON.parse(raw)))
    end

    assert_equal File.read(File.join(FIXTURES, "render.expected")), "#{lines.join("\n")}\n"
  end

  # --list byte-shape: both discovery roots hit, wt/ pruned, active ● vs stale
  # · beyond the window, and the <agent>:<lane> tag from a lane-worktree cwd.
  def test_looplog_list_inventories_both_roots_prunes_wt_and_flags_staleness
    root = Dir.mktmpdir("looplog-test")
    space = File.join(root, "space")
    sessions = File.join(root, "sessions")
    records = File.readlines(File.join(FIXTURES, "records.jsonl"))

    fresh_path = File.join(sessions, "-#{space.tr('/', '-')}--", "s1", "subagent-artifacts",
                           "11111111_architect-coordinator_transcript.jsonl")
    stale_path = File.join(space, "build", "loop", "launch1", "subagent-artifacts",
                           "22222222_architect-builder_transcript.jsonl")
    pruned_path = File.join(space, "build", "I07-gem", "wt", "subagent-artifacts",
                            "33333333_architect-judge_transcript.jsonl")
    fresh_mtime = write_and_stamp(fresh_path, records, 120)
    stale_mtime = write_and_stamp(stale_path, records, 1200)
    write_and_stamp(pruned_path, records, 60)

    out = StringIO.new
    Space::Architect::Looplog.list(
      space: space,
      io: out,
      env: { "PI_SESSIONS_DIR" => sessions, "NO_COLOR" => "1", "LOOPLOG_WINDOW" => "900" }
    )

    size = File.size(fresh_path) / 1024
    expected = [
      format("%s %-9s %5s %5.0fm %7sK  %s  %s",
             "●", "architect-coordinator:07-gem", Time.at(fresh_mtime).strftime("%H:%M"),
             (Time.now.to_f - fresh_mtime) / 60, size, "11111111", "Task: write the thing"),
      format("%s %-9s %5s %5.0fm %7sK  %s  %s",
             "·", "architect-builder:07-gem", Time.at(stale_mtime).strftime("%H:%M"),
             (Time.now.to_f - stale_mtime) / 60, size, "22222222", "Task: write the thing")
    ]
    assert_equal "#{expected.join("\n")}\n", out.string,
      "sessions-root and build-root transcripts listed, the wt/-pruned one absent, newest first"
  end

  # Staleness: transcripts beyond LOOPLOG_WINDOW are not adopted on follow
  # unless --all.
  def test_looplog_scan_skips_transcripts_stale_beyond_the_window_unless_all
    root = Dir.mktmpdir("looplog-test")
    space = File.join(root, "space")
    path = File.join(space, "build", "subagent-artifacts", "22222222_architect-builder_transcript.jsonl")
    write_and_stamp(path, File.readlines(File.join(FIXTURES, "records.jsonl")), 1200)

    out = StringIO.new
    follower = Space::Architect::Looplog::Follower.new(space: space, io: out,
                                                       env: { "NO_COLOR" => "1" }, replay: false, all: false)
    follower.scan
    assert_empty out.string, "a transcript 1200s old must not be adopted within the default 900s window"

    out = StringIO.new
    follower = Space::Architect::Looplog::Follower.new(space: space, io: out,
                                                       env: { "NO_COLOR" => "1" }, replay: false, all: true)
    follower.scan
    assert_includes out.string, "▶ architect-builder 22222222", "--all adopts the stale transcript"
  end

  # Follow: scan adopts a fresh run at its current end (banner, no history),
  # drain streams newly appended lines with the run tag + record stamp. The
  # exchange opened by the file's head user record is NOT in this renderer
  # (adoption starts at the end), so the done line carries no elapsed.
  def test_looplog_scan_adopts_fresh_run_and_drain_streams_new_lines
    path, records, _mtime, space = build_follow_tree
    out = StringIO.new
    follower = Space::Architect::Looplog::Follower.new(space: space,
                                                       io: out, env: { "NO_COLOR" => "1" },
                                                       replay: false, all: false)
    follower.scan

    banner, rest = out.string.split("\n", 2)
    assert_match(%r{\A\[architect-builder:07-gem\] \d{2}:\d{2}:\d{2} ▶ architect-builder 22222222  @ /tmp/looplog-space/build/I07-gem/wt — Task: write the thing\z}, banner,
                 "adoption prints the tagged banner with cwd and task")
    assert_equal "", rest, "a fresh adoption starts at the file's end — no history"

    File.open(path, "a") { |f| f.write(records[4..].join) }
    follower.drain(follower.runs.fetch(path))

    _banner, rest = out.string.split("\n", 2)
    assert_equal expected_lines(APPENDED_RENDER_LINES, elapsed: false), rest
  end

  # --replay: adoption at offset 0, so drain streams the whole existing history —
  # including the user record that opens the exchange (elapsed present).
  def test_looplog_replay_drains_full_history_with_tag_and_stamp
    path, _records, _mtime, space = build_follow_tree(all_records: true)
    out = StringIO.new
    follower = Space::Architect::Looplog::Follower.new(space: space, io: out,
                                                       env: { "NO_COLOR" => "1" }, replay: true, all: false)
    follower.scan

    banner, rest = out.string.split("\n", 2)
    assert_match(%r{\A\[architect-builder:07-gem\] \d{2}:\d{2}:\d{2} ▶ architect-builder 22222222  @ /tmp/looplog-space/build/I07-gem/wt — Task: write the thing\z}, banner)
    assert_equal "", rest, "adoption prints only the banner; history streams on drain"

    follower.drain(follower.runs.fetch(path))

    _banner2, rest = out.string.split("\n", 2)
    assert_equal expected_lines(FULL_RENDER_LINES, elapsed: true), rest
  end

  # The iteration-id-aware builder tag: architecture/I<NN>-<name>.md is the
  # authority for splitting a lane dir, so a hyphenated iteration slug cannot
  # bleed into the lane (I06-editor-markdown + markdown-seam lane). The
  # narrator maps to its own tag instead of truncating to "architect-".
  # Transcripts sit at build/<id>-<lane>/subagent-artifacts (wt/ subtrees are
  # pruned from build-root discovery); the recorded cwd drives the tag.
  def test_looplog_tag_resolves_lane_via_iteration_ids_and_abbreviates_narrator
    root = Dir.mktmpdir("looplog-test")
    space = File.join(root, "space")
    sessions = File.join(root, "sessions")
    records = File.readlines(File.join(FIXTURES, "records.jsonl"))

    FileUtils.mkdir_p(File.join(space, "architecture"))
    File.write(File.join(space, "architecture", "I06-editor-markdown.md"), "# iteration\n")
    seam_wt = File.join(space, "build", "I06-editor-markdown-markdown-seam", "wt")
    editor_wt = File.join(space, "build", "I06-editor-markdown-editor", "wt")
    seam_records = records.map { |r| r.gsub("/tmp/looplog-space/build/I07-gem/wt", seam_wt) }
    editor_records = records.map { |r| r.gsub("/tmp/looplog-space/build/I07-gem/wt", editor_wt) }
    write_and_stamp(File.join(seam_wt.delete_suffix("/wt"), "subagent-artifacts",
                             "44444444_architect-builder_transcript.jsonl"), seam_records, 120)
    write_and_stamp(File.join(editor_wt.delete_suffix("/wt"), "subagent-artifacts",
                             "55555555_architect-narrator_transcript.jsonl"), editor_records, 600)

    out = StringIO.new
    Space::Architect::Looplog.list(
      space: space,
      io: out,
      env: { "PI_SESSIONS_DIR" => sessions, "NO_COLOR" => "1", "LOOPLOG_WINDOW" => "900" }
    )

    lines = out.string.lines
    assert_match(/architect-builder:06-markdown-seam /, lines[0], "hyphenated lane resolved via the iteration id")
    assert_match(/architect-narrator:06-editor /, lines[1], "narrator shows its full agent name")
  end

  # ---- [I95 loop-parity] tart run/session records + the shared-renderer adapter ----

  # B-Law 2: run records from TART_SUBAGENTS_HOME — status.json identity, the
  # NEWEST <run>/sessions/**/*.jsonl as the transcript, the space-cwd scope
  # filter, and the silent skips (out-of-space cwd, malformed status.json, a
  # run with no transcript). id falls back to the dir name; the task is the
  # status task's first line under the list row's 70-col cut.
  def test_tart_run_records_newest_transcript_space_filter_and_skip_laws
    space, home, sessions = build_tart_tree
    stage_tart_run(space, home, mtime_offset: 120)
    out_of_space = File.join(home, "bbbb2222-2222-3333-4444-555566667777")
    FileUtils.mkdir_p(out_of_space)
    File.write(File.join(out_of_space, "status.json"), tart_status_fixture(cwd: "/tmp/elsewhere-bbbb"))
    malformed = File.join(home, "cccc3333-3333-3333-4444-555566667777")
    FileUtils.mkdir_p(File.join(malformed, "sessions", "x"))
    File.write(File.join(malformed, "status.json"), "{not json")
    File.write(File.join(malformed, "sessions", "x", "child.jsonl"), "#{tart_header_line(space)}\n")
    no_transcript = File.join(home, "dddd4444-4444-3333-4444-555566667777")
    FileUtils.mkdir_p(no_transcript)
    File.write(File.join(no_transcript, "status.json"), tart_status_fixture(space: space, run_dir: no_transcript))
    nameless = File.join(home, "eeee5555-5555-3333-4444-555566667777")
    FileUtils.mkdir_p(File.join(nameless, "sessions", "x"))
    status = tart_status_fixture(space: space, run_dir: nameless)
    File.write(File.join(nameless, "status.json"), status.sub(%q("id":"01a1d7de-b210-70ba-9280-a3f81da81800",), ""))
    nameless_path = File.join(nameless, "sessions", "x", "child.jsonl")
    nameless_mtime = write_and_stamp(nameless_path, [tart_header_line(space)], 60)

    out = StringIO.new
    Space::Architect::Looplog.list(space: space, io: out, env: tart_env(home, sessions))

    lines = out.string.lines
    assert_equal 2, lines.size,
                 "the in-space runs list newest-first; out-of-space, malformed, and transcript-less runs skip silently"
    new_path = File.join(home, "01a1d7de-b210-70ba-9280-a3f81da81800", "sessions", "kb-space-slug",
                         "2026-11-14T02-24-18-784Z_01a1d7de-b360-7aae-8593-1a1bd557a058.jsonl")
    task70 = "Read-only probe. NEVER print credential values — lengths and names onl"
    expected = [
      format("%s %-9s %5s %5.0fm %7sK  %s  %s", "●", "worker", Time.at(nameless_mtime).strftime("%H:%M"),
             (Time.now.to_f - nameless_mtime) / 60, File.size(nameless_path) / 1024, "eeee5555", task70),
      format("%s %-9s %5s %5.0fm %7sK  %s  %s", "●", "worker", Time.at(File.mtime(new_path)).strftime("%H:%M"),
             (Time.now.to_f - File.mtime(new_path).to_f) / 60, File.size(new_path) / 1024, "01a1d7de", task70)
    ]
    assert_equal "#{expected.join("\n")}\n", out.string,
                 "the NEWEST transcript of a run is the unit; the dir-name id fallback backs a missing status id"
  end

  # B-Law 2: a lane-worktree spawn cwd (<space>/build/<id>-<lane>/wt) stays in
  # scope and keeps the tag_label lane-tag law, resolved against the space's
  # architecture/I<NN>-<name>.md iteration ids.
  def test_tart_run_lane_worktree_cwd_resolves_the_lane_tag
    space, home, sessions = build_tart_tree
    FileUtils.mkdir_p(File.join(space, "architecture"))
    File.write(File.join(space, "architecture", "I95-loop-parity.md"), "# iteration\n")
    wt = File.join(space, "build", "I95-loop-parity-looplog-records", "wt")
    run_dir = File.join(home, "aaaa1111-2222-3333-4444-555566667777")
    FileUtils.mkdir_p(File.join(run_dir, "sessions", "slugx"))
    File.write(File.join(run_dir, "status.json"), tart_status_fixture(cwd: wt))
    write_and_stamp(File.join(run_dir, "sessions", "slugx", "child.jsonl"), [tart_header_line(wt)], 30)

    out = StringIO.new
    Space::Architect::Looplog.list(space: space, io: out, env: tart_env(home, sessions))

    assert_match(/\A●\s+worker:95-looplog-records /, out.string,
                 "the lane worktree keeps the <agent>:<ordinal>-<lane> tag law")
  end

  # B-Law 3: every *.jsonl under the tart slug dir lists under the gem's own
  # "(session)" label (LoopCost::SESSION_AGENT), with the session header's id
  # and cwd and the first user line as task; empty/malformed/headerless files
  # skip silently, wt/ prunes, and sibling slug dirs stay out of scope.
  def test_tart_session_records_session_label_header_identity_and_skip_laws
    space, home, sessions = build_tart_tree
    slug_dir = File.join(sessions, "-#{space.tr('/', '-')}--")
    FileUtils.mkdir_p(slug_dir)
    chat_path = File.join(slug_dir, "2026-10-10T20-12-49-313Z_01a12772-5f21-751c-a450-295ee2d133b0.jsonl")
    chat_mtime = write_lines_and_stamp(chat_path, TART_SESSION_CHAT_LINES, 120)
    File.write(File.join(slug_dir, "empty.jsonl"), "")
    File.write(File.join(slug_dir, "garbage.jsonl"), "not json at all\n")
    File.write(File.join(slug_dir, "headerless.jsonl"), TART_SESSION_CHAT_LINES.lines[1])
    wt_dir = File.join(slug_dir, "wt")
    FileUtils.mkdir_p(wt_dir)
    File.write(File.join(wt_dir, "pruned.jsonl"), TART_SESSION_CHAT_LINES)
    sibling = File.join(sessions, "-#{File.join(space, 'other').tr('/', '-')}--")
    FileUtils.mkdir_p(sibling)
    File.write(File.join(sibling, "x.jsonl"), TART_SESSION_CHAT_LINES)

    out = StringIO.new
    Space::Architect::Looplog.list(space: space, io: out, env: tart_env(home, sessions))

    expected = format("%s %-9s %5s %5.0fm %7sK  %s  %s", "●", "(session)",
                      Time.at(chat_mtime).strftime("%H:%M"), (Time.now.to_f - chat_mtime) / 60,
                      TART_SESSION_CHAT_LINES.bytesize / 1024, "01a12772", "hi")
    assert_equal "#{expected}\n", out.string,
                 "exactly the slug-dir session file lists — header id + first user line, empty/malformed/headerless skipped, wt/ pruned, sibling slugs invisible"
  end

  # B-Law 1: with no TART_* overrides the defaults are ~/.tart/* — they add no
  # rows for a space with no tart records — and the gem's own overrides steer
  # discovery at the staged roots.
  def test_tart_roots_default_home_when_env_unset_and_overrides_steer_discovery
    space, home, sessions = build_tart_tree
    stage_tart_run(space, home, mtime_offset: 60)

    out = StringIO.new
    Space::Architect::Looplog.list(space: space, io: out, env: { "NO_COLOR" => "1" })
    assert_empty out.string, "the default tart roots add no rows for a space with no tart records"

    out = StringIO.new
    Space::Architect::Looplog.list(space: space, io: out, env: tart_env(home, sessions))
    assert_equal 1, out.string.lines.size, "the overrides steer discovery at the staged tart roots"
  end

  # B-Law 4: a real-corpus transcript renders through the ONE Renderer via the
  # tart adapter — thinking dim, the one-lined ⚒ tool calls from synthesized
  # tool_starts, ← tool results with the line-count note, and the ✓ done line
  # with usage/exchange arithmetic shared with pi. Stamp law unchanged (local,
  # from the projected record's ts). Fixture provenance in the lane report.
  def test_tart_transcript_renders_through_the_shared_renderer_from_the_real_corpus_fixture
    space, home, sessions = build_tart_tree
    path = stage_tart_run(space, home, mtime_offset: 30)
    out = StringIO.new
    follower = Space::Architect::Looplog::Follower.new(space: space, io: out,
                                                       env: tart_env(home, sessions),
                                                       replay: true, all: false)
    follower.scan

    banner, rest = out.string.split("\n", 2)
    assert_match(%r{\A\[worker\] \d{2}:\d{2}:\d{2} ▶ worker 01a1d7de  @ #{Regexp.escape(space)} — Read-only probe\. NEVER print credential values — lengths and names only\.\z}, banner,
                 "adoption prints the tagged banner with the status.json cwd and task")
    assert_equal "", rest, "adoption prints only the banner; history streams on drain"

    follower.drain(follower.runs.fetch(path))
    _banner, rest = out.string.split("\n", 2)
    assert_equal expected_tart_lines(TART_RENDER_TIMELINE), rest,
                 "the shared renderer renders the tart vocabulary: thinking, ⚒ calls, ← results, ✓ done"
  end

  # B-Law 4 mappings: finish_reason tool_calls → toolUse (no done line until a
  # final stop), stop → end_turn, length/error verbatim (error keys the ✗ arm);
  # usage maps output_tokens→output and cache_write_tokens→the cache slot,
  # never cache_read_tokens, never cost; a usage-less assistant still closes
  # the exchange with zeros and no elapsed.
  def test_tart_adapter_finish_reason_and_usage_mapping
    space, home, sessions = build_tart_tree
    run_dir = File.join(home, "aaaa1111-2222-3333-4444-555566667777")
    FileUtils.mkdir_p(File.join(run_dir, "sessions", "x"))
    File.write(File.join(run_dir, "status.json"), tart_status_fixture(space: space, run_dir: run_dir))
    path = File.join(run_dir, "sessions", "x", "child.jsonl")
    write_lines_and_stamp(path, MAPPING_TRANSCRIPT_LINES, 30)
    out = StringIO.new
    follower = Space::Architect::Looplog::Follower.new(space: space, io: out,
                                                       env: tart_env(home, sessions),
                                                       replay: true, all: false)
    follower.scan
    follower.drain(follower.runs.fetch(path))
    _banner, rest = out.string.split("\n", 2)

    assert_equal expected_tart_lines(MAPPING_RENDER_TIMELINE), rest,
                 "finish_reason/usage map onto the shared ✓/✗ law with no fabricated numbers"
  end

  private

  # [ts (epoch s), rendered line] for records.jsonl's non-silent records —
  # system/tool_end records emit nothing and are absent here.
  FULL_RENDER_LINES = [
    [1_700_000_001, "⚒ read path: /tmp/a.txt"],
    [1_700_000_001.2, "← alpha beta gamma delta epsilon (3 lines)"],
    [1_700_000_002, "· thinking"],
    [1_700_000_002, "step one"],
    [1_700_000_002, "step two"],
    [1_700_000_002, "● assistant"],
    [1_700_000_002, "Doing it."],
    [1_700_000_003, "⚒ edit path=/tmp/b.txt verbose=true"],
    [1_700_000_003.1, "✗ boom"],
    [1_700_000_004, "● assistant"],
    [1_700_000_004, "Done."],
    [1_700_000_004, "✓ done  7 out  3 cache read  $0.00  4s"]
  ].freeze

  # The appended half only (records 5..): the exchange opener was skipped.
  APPENDED_RENDER_LINES = FULL_RENDER_LINES.reject { |ts, _| ts < 1_700_000_002 }.map do |ts, line|
    [ts, line.sub("  4s", "")]
  end.freeze

  def expected_lines(render_lines, elapsed:)
    render_lines.map { |ts, line| "[architect-builder:07-gem] #{Time.at(ts).strftime('%H:%M:%S')} #{line}" }
                .join("\n") << "\n"
  end

  # A space/build transcript holding the user-opening records (or the whole
  # record set for --replay), fresh within the adoption window. Returns
  # [path, records, mtime, space].
  def build_follow_tree(all_records: false)
    root = Dir.mktmpdir("looplog-test")
    space = File.join(root, "space")
    path = File.join(space, "build", "subagent-artifacts", "22222222_architect-builder_transcript.jsonl")
    records = File.readlines(File.join(FIXTURES, "records.jsonl"))
    mtime = write_and_stamp(path, all_records ? records : records[0, 4], 30)

    [path, records, mtime, space]
  end

  def write_and_stamp(path, records, offset)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, records.join)
    m = Time.now.to_f - offset
    File.utime(m, m, path)
    m
  end
  # ---- [I95 loop-parity] real-corpus tart fixtures (byte-verbatim
  # transcriptions; provenance in build/I95-loop-parity-looplog-records/
  # report.md). Staged tests gsub the recorded KB paths onto their tmp trees —
  # the fixture bytes are the real corpus's. TART_RUN_STATUS: the status.json
  # of run 01a1d7de-b210-70ba-9280-a3f81da81800 (a KB read-only probe worker,
  # state completed). RUN_TRANSCRIPT_LINES: that run's only child session,
  # sessions/--Users-eric-architect-spaces-20261110-knowledge-builder--/
  # 2026-11-14T02-24-18-784Z_01a1d7de-b360-7aae-8593-1a1bd557a058.jsonl
  # (session id 01a1d7de-b360-7aae-8593-1a1bd557a058). TART_SESSION_CHAT_LINES:
  # this space's own tart slug-dir session 2026-10-10T20-12-49-313Z_
  # 01a12772-5f21-751c-a450-295ee2d133b0.jsonl — the agent-less "(session)"
  # kind. These fixtures live HERE rather than under test/fixtures/looplog/
  # because the frozen gem-scope gate's anchored allow regex cannot match a
  # new loose fixture file in this never-committed lane tree (measured: git
  # status prints new files there as untracked file paths; a directory
  # collapses in porcelain only when wholly untracked, and the two byte-frozen
  # pi fixtures keep test/fixtures/looplog/ tracked).
  TART_RUN_STATUS = <<~'JSON'
{"id":"01a1d7de-b210-70ba-9280-a3f81da81800","agent":"worker","task":"Read-only probe. NEVER print credential values — lengths and names only.\n\n1. ruby -rjson -e 'j=JSON.parse(File.read(ENV[\"HOME\"]+\"/.pi/agent/auth.json\")); j.each{|k,v| kp=v[\"key\"].to_s; puts \"#{k}: type=#{v[\"type\"]} key_length=#{kp.length} prefix=#{kp[0,3]==\"sk-\"?\"sk-\":\"other\"}\" }' 2>&1\n2. ruby -rjson -e 'j=JSON.parse(File.read(ENV[\"HOME\"]+\"/.pi/agent/settings.json\")); puts \"defaultProvider=#{j[\"defaultProvider\"].inspect}\"; puts \"defaultModel=#{j[\"defaultModel\"].inspect}\"; puts \"defaultThinkingLevel=#{j[\"defaultThinkingLevel\"].inspect}\"' 2>&1\n\nReport raw output only.","taskChars":572,"mode":"single","state":"completed","pid":10227,"cwd":"/Users/eric/architect/spaces/20261110-knowledge-builder","asyncDir":"/Users/eric/.tart/subagents/01a1d7de-b210-70ba-9280-a3f81da81800","sessionRoot":"/Users/eric/.tart/subagents/01a1d7de-b210-70ba-9280-a3f81da81800/sessions","startedAt":1794623058450,"lastUpdate":1794623069661,"toolCallId":null,"context":"fresh","timeoutMs":120000,"endedAt":1794623069661,"timedOut":false,"outputFile":"/Users/eric/.tart/subagents/01a1d7de-b210-70ba-9280-a3f81da81800/result.json"}
  JSON
  RUN_TRANSCRIPT_LINES = <<~'JSON'
{"type":"session","version":3,"id":"01a1d7de-b360-7aae-8593-1a1bd557a058","timestamp":"2026-11-14T02:24:18.784Z","cwd":"/Users/eric/architect/spaces/20261110-knowledge-builder"}
{"type":"message","id":"1f9ce5e9","parentId":null,"timestamp":"2026-11-14T02:24:18.798Z","message":{"role":"user","content":"Read-only probe. NEVER print credential values — lengths and names only.\n\n1. ruby -rjson -e 'j=JSON.parse(File.read(ENV[\"HOME\"]+\"/.pi/agent/auth.json\")); j.each{|k,v| kp=v[\"key\"].to_s; puts \"#{k}: type=#{v[\"type\"]} key_length=#{kp.length} prefix=#{kp[0,3]==\"sk-\"?\"sk-\":\"other\"}\" }' 2>&1\n2. ruby -rjson -e 'j=JSON.parse(File.read(ENV[\"HOME\"]+\"/.pi/agent/settings.json\")); puts \"defaultProvider=#{j[\"defaultProvider\"].inspect}\"; puts \"defaultModel=#{j[\"defaultModel\"].inspect}\"; puts \"defaultThinkingLevel=#{j[\"defaultThinkingLevel\"].inspect}\"' 2>&1\n\nReport raw output only."}}
{"type":"message","id":"db1027ae","parentId":"1f9ce5e9","timestamp":"2026-11-14T02:24:24.286Z","message":{"role":"assistant","content":"","tool_calls":{"call_be373a989beb4d17bcdb19e3":{"id":"call_be373a989beb4d17bcdb19e3","name":"bash","arguments":{"command":"ruby -rjson -e 'j=JSON.parse(File.read(ENV[\"HOME\"]+\"/.pi/agent/auth.json\")); j.each{|k,v| kp=v[\"key\"].to_s; puts \"#{k}: type=#{v[\"type\"]} key_length=#{kp.length} prefix=#{kp[0,3]==\"sk-\"?\"sk-\":\"other\"}\" }' 2>&1","timeout":30}},"call_169dee1fe1594f3898585075":{"id":"call_169dee1fe1594f3898585075","name":"bash","arguments":{"command":"ruby -rjson -e 'j=JSON.parse(File.read(ENV[\"HOME\"]+\"/.pi/agent/settings.json\")); puts \"defaultProvider=#{j[\"defaultProvider\"].inspect}\"; puts \"defaultModel=#{j[\"defaultModel\"].inspect}\"; puts \"defaultThinkingLevel=#{j[\"defaultThinkingLevel\"].inspect}\"' 2>&1","timeout":30}}},"provider":"zai","model":"glm-5.3","thinking":"The user wants me to run two read-only probe commands. These are Ruby commands that read JSON files and print non-credential info (names, lengths, prefixes). Let me run them.","thinking_signature":"reasoning_content","finish_reason":"tool_calls","input_tokens":229,"output_tokens":218,"cache_read_tokens":2816,"cache_write_tokens":0,"thinking_tokens":38}}
{"type":"message","id":"7bfa62b7","parentId":"db1027ae","timestamp":"2026-11-14T02:24:24.341Z","message":{"role":"tool","content":"zai: type=api_key key_length=12 prefix=other\nopenrouter: type=api_key key_length=19 prefix=other\nkimi-coding: type=api_key key_length=13 prefix=other\n","tool_call_id":"call_be373a989beb4d17bcdb19e3"}}
{"type":"message","id":"91d6bf61","parentId":"7bfa62b7","timestamp":"2026-11-14T02:24:24.341Z","message":{"role":"tool","content":"defaultProvider=\"zai\"\ndefaultModel=\"glm-5.3\"\ndefaultThinkingLevel=\"high\"\n","tool_call_id":"call_169dee1fe1594f3898585075"}}
{"type":"message","id":"6383d3f0","parentId":"91d6bf61","timestamp":"2026-11-14T02:24:29.303Z","message":{"role":"assistant","content":"Command 1 raw output:\n```\nzai: type=api_key key_length=12 prefix=other\nopenrouter: type=api_key key_length=19 prefix=other\nkimi-coding: type=api_key key_length=13 prefix=other\n```\n\nCommand 2 raw output:\n```\ndefaultProvider=\"zai\"\ndefaultModel=\"glm-5.3\"\ndefaultThinkingLevel=\"high\"\n```\n\nNo edits made (read-only probe, as instructed).","tool_calls":{},"provider":"zai","model":"glm-5.3","thinking":"Both commands ran successfully. Report raw output only, no credential values printed (only lengths and names were printed, as the commands themselves were designed to do).","thinking_signature":"reasoning_content","finish_reason":"stop","input_tokens":329,"output_tokens":132,"cache_read_tokens":3008,"cache_write_tokens":0,"thinking_tokens":31}}
  JSON
  TART_SESSION_CHAT_LINES = <<~'JSON'
{"type":"session","version":3,"id":"01a12772-5f21-751c-a450-295ee2d133b0","timestamp":"2026-10-10T20:12:49.313Z","cwd":"/Users/eric/architect/spaces/20261009-pi-port"}
{"type":"message","id":"d001257f","parentId":null,"timestamp":"2026-10-10T20:13:02.783Z","message":{"role":"user","content":"hi"}}
{"type":"message","id":"5125f2f5","parentId":"d001257f","timestamp":"2026-10-10T20:13:03.741Z","message":{"role":"assistant","content":"Hi! How can I help you today? I'm ready to assist with reading, writing, or editing files, running commands, searching code, and more.","model":"accounts/fireworks/models/glm-5p3-flash","tool_calls":{},"finish_reason":"stop","input_tokens":43,"output_tokens":62,"cache_read_tokens":1280,"cache_write_tokens":0,"thinking_tokens":28}}
  JSON

  RUN_TRANSCRIPT_ISOS = [
    "2026-11-14T02:24:18.798Z", # user — the exchange opener (no output)
    "2026-11-14T02:24:24.286Z", # assistant: thinking + two bash tool_calls
    "2026-11-14T02:24:24.341Z", # tool result (auth probe)
    "2026-11-14T02:24:24.341Z", # tool result (settings probe)
    "2026-11-14T02:24:29.303Z"  # assistant: thinking + text + stop
  ].freeze

  RUN_TRANSCRIPT_CALL_ARGS = RUN_TRANSCRIPT_LINES.lines.filter_map { |l|
    rec = begin
      JSON.parse(l)
    rescue JSON::ParserError
      next
    end
    next unless rec.is_a?(Hash) && rec["type"] == "message" && rec.dig("message", "role") == "assistant"

    calls = rec.dig("message", "tool_calls")
    calls.is_a?(Hash) ? calls.values.filter_map { |c| c.is_a?(Hash) ? c["arguments"] : nil } : nil
  }.flatten.freeze

  # The rendered timeline of RUN_TRANSCRIPT_LINES through the shared renderer
  # (hand-pinned display bytes; stamps local via the ts the adapter projects).
  TART_RENDER_TIMELINE = [
    [RUN_TRANSCRIPT_ISOS[1], "· thinking"],
    [RUN_TRANSCRIPT_ISOS[1], "The user wants me to run two read-only probe commands. These are Ruby commands that read JSON files and print non-credential info (names, lengths, prefixes). Let me run them."],
    [RUN_TRANSCRIPT_ISOS[1], "⚒ bash command: #{RUN_TRANSCRIPT_CALL_ARGS[0]['command']}  timeout: 30"],
    [RUN_TRANSCRIPT_ISOS[1], "⚒ bash command: #{RUN_TRANSCRIPT_CALL_ARGS[1]['command']}  timeout: 30"],
    [RUN_TRANSCRIPT_ISOS[2], "← zai: type=api_key key_length=12 prefix=other openrouter: type=api_key key_length=19 prefix=other kimi-coding: type=api_key key_length=13 prefix=other (3 lines)"],
    [RUN_TRANSCRIPT_ISOS[3], "← defaultProvider=\"zai\" defaultModel=\"glm-5.3\" defaultThinkingLevel=\"high\" (3 lines)"],
    [RUN_TRANSCRIPT_ISOS[4], "· thinking"],
    [RUN_TRANSCRIPT_ISOS[4], "Both commands ran successfully. Report raw output only, no credential values printed (only lengths and names were printed, as the commands themselves were designed to do)."],
    [RUN_TRANSCRIPT_ISOS[4], "● assistant"],
    [RUN_TRANSCRIPT_ISOS[4], "Command 1 raw output:"],
    [RUN_TRANSCRIPT_ISOS[4], "```"],
    [RUN_TRANSCRIPT_ISOS[4], "zai: type=api_key key_length=12 prefix=other"],
    [RUN_TRANSCRIPT_ISOS[4], "openrouter: type=api_key key_length=19 prefix=other"],
    [RUN_TRANSCRIPT_ISOS[4], "kimi-coding: type=api_key key_length=13 prefix=other"],
    [RUN_TRANSCRIPT_ISOS[4], "```"],
    [RUN_TRANSCRIPT_ISOS[4], "Command 2 raw output:"],
    [RUN_TRANSCRIPT_ISOS[4], "```"],
    [RUN_TRANSCRIPT_ISOS[4], "defaultProvider=\"zai\""],
    [RUN_TRANSCRIPT_ISOS[4], "defaultModel=\"glm-5.3\""],
    [RUN_TRANSCRIPT_ISOS[4], "defaultThinkingLevel=\"high\""],
    [RUN_TRANSCRIPT_ISOS[4], "```"],
    [RUN_TRANSCRIPT_ISOS[4], "No edits made (read-only probe, as instructed)."],
    [RUN_TRANSCRIPT_ISOS[4], "✓ done  132 out  0 cache read  11s"]
  ].freeze

  # A corpus-shaped mapping pin: toolUse opens a tool call with no done line,
  # stop closes with the cache_write mapping, length closes verbatim, error
  # closes into the shared ✗ arm with zeros and no elapsed (exchange closed).
  MAPPING_TRANSCRIPT_LINES = <<~'JSON'
    {"type":"session","version":3,"id":"mapping","timestamp":"2026-11-14T03:00:00.000Z","cwd":"/mapping-space"}
    {"type":"message","id":"u1","parentId":null,"timestamp":"2026-11-14T03:00:00.000Z","message":{"role":"user","content":"open"}}
    {"type":"message","id":"a1","parentId":"u1","timestamp":"2026-11-14T03:00:01.000Z","message":{"role":"assistant","content":"","tool_calls":{"call_1":{"id":"call_1","name":"read","arguments":{"path":"/a"}}},"finish_reason":"tool_calls","input_tokens":100,"output_tokens":5,"cache_write_tokens":0}}
    {"type":"message","id":"t1","parentId":"a1","timestamp":"2026-11-14T03:00:01.100Z","message":{"role":"tool","content":"file body","tool_call_id":"call_1"}}
    {"type":"message","id":"a2","parentId":"t1","timestamp":"2026-11-14T03:00:02.000Z","message":{"role":"assistant","content":"mid","tool_calls":{},"finish_reason":"stop","output_tokens":9,"cache_write_tokens":500}}
    {"type":"message","id":"u2","parentId":"a2","timestamp":"2026-11-14T03:00:10.000Z","message":{"role":"user","content":"again"}}
    {"type":"message","id":"a3","parentId":"u2","timestamp":"2026-11-14T03:00:12.000Z","message":{"role":"assistant","content":"trimmed","tool_calls":{},"finish_reason":"length","output_tokens":3,"cache_write_tokens":0}}
    {"type":"message","id":"a4","parentId":"a3","timestamp":"2026-11-14T03:00:13.000Z","message":{"role":"assistant","content":"","tool_calls":{},"finish_reason":"error"}}
  JSON

  MAPPING_RENDER_TIMELINE = [
    ["2026-11-14T03:00:01.000Z", "⚒ read path: /a"],
    ["2026-11-14T03:00:01.100Z", "← file body"],
    ["2026-11-14T03:00:02.000Z", "● assistant"],
    ["2026-11-14T03:00:02.000Z", "mid"],
    ["2026-11-14T03:00:02.000Z", "✓ done  9 out  500 cache read  2s"],
    ["2026-11-14T03:00:12.000Z", "● assistant"],
    ["2026-11-14T03:00:12.000Z", "trimmed"],
    ["2026-11-14T03:00:12.000Z", "✓ done  3 out  0 cache read  2s"],
    ["2026-11-14T03:00:13.000Z", "✗ failed  0 out  0 cache read"]
  ].freeze

  def build_tart_tree
    root = Dir.mktmpdir("looplog-tart")
    space = File.join(root, "space")
    home = File.join(root, "subagents")
    sessions = File.join(root, "sessions")
    FileUtils.mkdir_p(space)
    [space, home, sessions]
  end

  def tart_env(home, sessions)
    { "TART_SUBAGENTS_HOME" => home, "TART_SESSIONS_DIR" => sessions, "NO_COLOR" => "1" }
  end

  # Stages the real-corpus fixture run under home and returns its newest
  # transcript path.
  def stage_tart_run(space, home, mtime_offset: 30, transcripts: RUN_TRANSCRIPT_LINES, status: nil)
    run_dir = File.join(home, "01a1d7de-b210-70ba-9280-a3f81da81800")
    FileUtils.mkdir_p(File.join(run_dir, "sessions", "kb-space-slug"))
    File.write(File.join(run_dir, "status.json"),
               status || tart_status_fixture(space: space, run_dir: run_dir))
    path = File.join(run_dir, "sessions", "kb-space-slug",
                     "2026-11-14T02-24-18-784Z_01a1d7de-b360-7aae-8593-1a1bd557a058.jsonl")
    write_lines_and_stamp(path, transcripts, mtime_offset)
    path
  end

  # write_and_stamp joins an Array of lines; the fixture constants are raw
  # byte strings.
  def write_lines_and_stamp(path, content, offset)
    write_and_stamp(path, content.is_a?(Array) ? content : content.lines, offset)
  end

  # The real status.json with its recorded KB paths gsubbed onto the staged
  # tree (cwd/sessionRoot/asyncDir/outputFile) — the bytes stay the corpus's.
  def tart_status_fixture(space: nil, run_dir: nil, cwd: nil)
    status = TART_RUN_STATUS.gsub(
      "/Users/eric/.tart/subagents/01a1d7de-b210-70ba-9280-a3f81da81800", run_dir.to_s
    )
    status.gsub("/Users/eric/architect/spaces/20261110-knowledge-builder", (cwd || space).to_s)
  end

  def tart_header_line(cwd)
    "{\"type\":\"session\",\"version\":3,\"id\":\"01a1d7de-b360-7aae-8593-1a1bd557a058\"," \
      "\"timestamp\":\"2026-11-14T02:24:18.784Z\",\"cwd\":\"#{cwd}\"}\n"
  end

  def expected_tart_lines(timeline)
    timeline.map { |iso, line| "[worker] #{Time.at(Time.parse(iso).to_f).strftime('%H:%M:%S')} #{line}" }
            .join("\n") << "\n"
  end

end


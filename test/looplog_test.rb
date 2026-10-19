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
end


# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "json"
require "open3"

# I16 — the five emission call sites, driven through the real loop dance on a
# real fixture space with a recording fake emitter; plus inertness (dead
# server, unconfigured) and the `architect emit` re-derivation properties.
class IterationEmissionHooksTest < Space::ArchitectTest
  TOKEN = "sat_hook_#{SecureRandom.hex(8)}"

  # Recording fake emitter: one entry per attempt, the SERIALIZED payload
  # bytes (the byte-identity currency for re-derivation comparisons).
  class RecordingEmitter
    attr_reader :calls

    def initialize
      @calls = []
    end

    def post(mouth, payload)
      @calls << [mouth, JSON.generate(payload)]
      { status: 200, body: { "ok" => true } }
    end
  end

  # ---- fixture helpers (test_helper.rb / pre-existing test files are out of
  # ---- bounds; duplicated per the pin_global_absent precedent) -------------

  def create_real_space(dir)
    FileUtils.mkdir_p(File.join(dir, "architecture"))
    FileUtils.mkdir_p(File.join(dir, "repos"))
    FileUtils.mkdir_p(File.join(dir, "tmp"))

    data = {
      "version" => 1, "id" => "test-space", "title" => "My Space", "status" => "active",
      "created_at" => "2026-06-19T00:00:00Z", "updated_at" => "2026-06-19T00:00:00Z",
      "repos" => [], "notes" => [], "tickets" => [], "tags" => []
    }
    yaml = YAML.dump(data)
    File.write(File.join(dir, "space.yaml"), yaml)
    FileUtils.cp_r(File.join(Space::GitFixtureTemplate.space_dir(yaml), ".git"), dir)

    Space::Core::Space.load(dir)
  end

  def create_real_repo(space_dir, name)
    repo_dir = File.join(space_dir, "repos", name)
    FileUtils.mkdir_p(repo_dir)
    FileUtils.cp_r(File.join(Space::GitFixtureTemplate.repo_dir, ".git"), repo_dir)
    File.write(File.join(repo_dir, "README.md"), "# #{name}\n")
    repo_dir
  end

  def pin_emission_absent(dir)
    @saved_emission_config = ENV["SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG"]
    @saved_global_routing = ENV["SPACE_ARCHITECT_GLOBAL_CONFIG"]
    ENV["SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG"] = File.join(dir, "absent-emission.yaml")
    # Also pin the ROUTING global layer to a missing path (the
    # pin_global_absent precedent): otherwise the machine's real
    # ~/.config/space-architect/architect.yaml leaks the builder model/effort
    # into the lane records under test.
    ENV["SPACE_ARCHITECT_GLOBAL_CONFIG"] = File.join(dir, "absent-routing.yaml")
  end

  def restore_emission_config
    if @saved_emission_config
      ENV["SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG"] = @saved_emission_config
    else
      ENV.delete("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG")
    end
    if @saved_global_routing
      ENV["SPACE_ARCHITECT_GLOBAL_CONFIG"] = @saved_global_routing
    else
      ENV.delete("SPACE_ARCHITECT_GLOBAL_CONFIG")
    end
  end

  SPEC_BODY = <<~SPEC
    - Objective — prove the emission hooks.
    ```lanes
    - name: lane-a
      repo: demo-repo
      touch: ["feature.rb"]
    ```
  SPEC

  AC_BODY = <<~AC
    **AC1.** the sentinel file exists.
    ```gates
    - id: G0
      ac: AC1
      cmd: "test -f feature.rb"
      expect:
        exit_code: 0
    - id: G1
      ac: AC1
      cmd: 'printf ''12 things\\n'''
      expect:
        threshold:
          match: '(\\d+) things'
          op: ">="
          value: 10
    ```
  AC

  VERDICT_BODY = <<~VERDICT
    Gates green, bounds clean.
    ```rulings
    ac_rulings:
      - ac: AC1
        ruling: PASS
        note: sentinel present
    phase0_resolutions:
      - topic: model default
        lane: lane-a
        resolution: took the CLI path
    ```
  VERDICT

  # The real loop dance. Returns [project, fake, transcript_path, freeze_sha].
  def run_dance(space, run_gate: true)
    fake = RecordingEmitter.new
    project = Space::Architect::ArchitectProject.new(space: space, emitter: fake)
    captured = {}
    capture_io do
      project.new_iteration!("dance")
      project.write_section!("dance", "specification", body: SPEC_BODY)
      project.write_section!("dance", "acceptance-criteria", body: AC_BODY)
      captured[:freeze_sha] = project.freeze!("dance", skip_rehearse_reason: "test emission dance")
      project.provision("dance", base: "main")
      wt = space.path.join("build", "I01-dance-lane-a", "wt")
      File.write(File.join(wt, "feature.rb"), "puts 'hello'\n")
      results = project.run_gates("dance", lane: "lane-a") if run_gate
      captured[:transcript] = results && project.gate_transcript("dance", results, lane: "lane-a")
      FileUtils.mkdir_p(space.path.join("build", "I01-dance-lane-a"))
      File.write(space.path.join("build", "I01-dance-lane-a", "report.md"),
        "raw numbers\nSTATUS: COMPLETE\n")
      project.transcribe_evidence!("dance", lane: "lane-a")
      project.record_verdict!("dance", decision: "continue", body: VERDICT_BODY)
    end
    [project, fake, captured[:transcript], captured[:freeze_sha]]
  end

  def recorded(fake, mouth)
    fake.calls.select { |m, _| m == mouth }
  end

  # Order-insensitive shape comparison (the builder fixes key order; JSON
  # bytes are only compared builder-vs-builder in the re-derivation tests).
  def assert_json(actual, expected)
    assert_equal expected, JSON.parse(actual)
  end

  def repo_head_sha(space, repo, ref = "main")
    out, = Open3.capture3("git", "-C", space.path.join("repos", repo).to_s, "rev-parse", ref)
    out.strip
  end

  # ---- call-site payload fidelity ------------------------------------------

  def test_freeze_emits_identity_and_frozen_gates
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    _project, fake, = run_dance(space, run_gate: false)

    freeze_calls = recorded(fake, "freeze")
    assert_equal 1, freeze_calls.size
    sha = space.data.dig("project", "iterations", 0, "freeze_sha")
    assert_json freeze_calls.first[1],
      {
        "iteration" => { "ordinal" => 1, "name" => "dance", "freeze_sha" => sha,
                         "branch" => "main", "status" => "frozen" },
        "gates" => [
          { "id" => "G0", "ac" => "AC1", "cmd" => "test -f feature.rb", "expect" => { "exit_code" => 0 } },
          { "id" => "G1", "ac" => "AC1", "cmd" => "printf '12 things\\n'",
            "expect" => { "threshold" => { "match" => '(\d+) things', "op" => ">=", "value" => 10 } } }
        ]
      }
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  def test_evidence_emits_lane_completion_from_space_yaml_record
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    _project, fake, = run_dance(space, run_gate: false)

    lane_calls = recorded(fake, "lane")
    assert_equal 1, lane_calls.size
    base_sha = repo_head_sha(space, "demo-repo")
    assert_json lane_calls.first[1],
      {
        "iteration" => { "ordinal" => 1, "name" => "dance" },
        "lane" => { "name" => "lane-a", "repo" => "demo-repo", "base_sha" => base_sha,
                    "harness" => "pi", "model" => Space::Architect::Harness::DEFAULT_MODEL,
                    "touch_set" => ["feature.rb"], "status" => "complete" }
      }
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  def test_unlabeled_evidence_of_multi_lane_iteration_emits_nothing
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    two_lanes = <<~SPEC
      - Objective — prove the emission hooks.
      ```lanes
      - name: lane-a
        repo: demo-repo
        touch: ["feature.rb"]
      - name: lane-b
        repo: demo-repo
        touch: ["other.rb"]
      ```
    SPEC
    project = Space::Architect::ArchitectProject.new(space: space)
    capture_io do
      project.new_iteration!("dance")
      project.write_section!("dance", "specification", body: two_lanes)
      project.write_section!("dance", "acceptance-criteria", body: AC_BODY)
      project.freeze!("dance", skip_rehearse_reason: "test")
    end
    assert_equal 2, space.data.dig("project", "iterations", 0, "lanes").size
    FileUtils.mkdir_p(space.path.join("build", "I01-dance"))
    File.write(space.path.join("build", "I01-dance", "report.md"), "x\nSTATUS: COMPLETE\n")
    fake = RecordingEmitter.new
    unlabeled = Space::Architect::ArchitectProject.new(space: space, emitter: fake)
    capture_io { unlabeled.transcribe_evidence!("dance") }
    assert_empty fake.calls
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  def test_gate_emits_results_and_sidecar_beside_unchanged_md
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    project, fake, transcript, = run_dance(space)

    # The dance orders gate BEFORE evidence: the gate-time lane call comes
    # first, the completion call second.
    lane_calls = recorded(fake, "lane")
    assert_equal 2, lane_calls.size
    md = File.read(transcript)
    base_sha = repo_head_sha(space, "demo-repo")
    assert_json lane_calls.first[1],
      {
        "iteration" => { "ordinal" => 1, "name" => "dance" },
        "lane" => {
          "name" => "lane-a", "repo" => "demo-repo", "base_sha" => base_sha,
          "harness" => "pi", "model" => Space::Architect::Harness::DEFAULT_MODEL,
          "touch_set" => ["feature.rb"],
          "gate_results" => [
            { "gate_id" => "G0", "status" => "pass", "transcript" => md },
            { "gate_id" => "G1", "status" => "pass", "transcript" => md }
          ]
        }
      }

    sidecar_path = Pathname.new(transcript.to_s.sub(/\.md\z/, ".json"))
    assert_path_exists sidecar_path
    mirror = JSON.parse(sidecar_path.read)
    assert_equal %w[gate_id status reason stdout stderr exit_code cmd dir], mirror.first.keys
    assert_equal %w[G0 G1], mirror.map { |g| g["gate_id"] }
    assert_equal %w[pass pass], mirror.map { |g| g["status"] }
    assert_equal "test -f feature.rb", mirror.first["cmd"]
    assert_equal 0, mirror.first["exit_code"]
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  FAIL_AC_BODY = <<~AC
    **AC1.** the sentinel file exists.
    ```gates
    - id: G0
      ac: AC1
      cmd: "test -f feature.rb"
      expect:
        exit_code: 0
    - id: G1
      ac: AC1
      cmd: 'printf ''12 things\n'''
      expect:
        threshold:
          match: '(\\d+) things'
          op: ">="
          value: 10
    - id: G2
      ac: AC1
      cmd: "false"
      expect:
        exit_code: 0
    ```
  AC

  def test_gate_run_statuses_carry_fail_exactly
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    fake = RecordingEmitter.new
    project = Space::Architect::ArchitectProject.new(space: space, emitter: fake)
    capture_io do
      project.new_iteration!("dance")
      project.write_section!("dance", "specification", body: SPEC_BODY)
      project.write_section!("dance", "acceptance-criteria", body: FAIL_AC_BODY)
      project.freeze!("dance", skip_rehearse_reason: "test")
      project.provision("dance", base: "main")
      wt = space.path.join("build", "I01-dance-lane-a", "wt")
      File.write(File.join(wt, "feature.rb"), "puts 'hello'\n")
      results = project.run_gates("dance", lane: "lane-a")
      project.gate_transcript("dance", results, lane: "lane-a")
    end

    lane_payload = JSON.parse(recorded(fake, "lane").first[1])
    statuses = lane_payload["lane"]["gate_results"].map { |r| r["status"] }
    assert_equal %w[pass pass fail], statuses
    failed = lane_payload["lane"]["gate_results"].last
    assert_equal "G2", failed["gate_id"]
    assert_equal "exit_code 1 != 0", failed["reason"]
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  def test_verdict_emits_decision_and_parsed_rulings
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    _project, fake, = run_dance(space)

    verdict_calls = recorded(fake, "verdict")
    assert_equal 1, verdict_calls.size
    assert_json verdict_calls.first[1],
      {
        "iteration" => { "ordinal" => 1, "name" => "dance" },
        "verdict" => {
          "decision" => "continue",
          "ac_rulings" => [{ "ac" => "AC1", "ruling" => "PASS", "note" => "sentinel present" }],
          "phase0_resolutions" => [{ "topic" => "model default", "lane" => "lane-a",
                                     "resolution" => "took the CLI path" }]
        }
      }
    # The ```rulings block lands in the markdown verbatim.
    assert_includes File.read(space.path.join("architecture", "I01-dance.md")), "```rulings"
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  def test_integrate_emits_integration_then_integrated_lane_re_emission
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    project, fake, = run_dance(space)
    capture_io { project.integrate!("dance", lanes: ["lane-a"]) }

    integration_calls = recorded(fake, "integration")
    assert_equal 1, integration_calls.size
    entry = space.data.dig("project", "iterations", 0)
    lane = entry["lanes"].first
    # The live integration call carries the repo's MERGE commit (the tip of the
    # integration branch after --no-ff merge).
    merge_commit, = Open3.capture3("git", "-C", space.path.join("repos", "demo-repo").to_s,
      "rev-parse", "project/my-space")
    assert_json integration_calls.first[1],
      {
        "iteration" => { "ordinal" => 1, "name" => "dance", "status" => "integrated" },
        "integration" => {
          "branch" => "project/my-space",
          "lanes" => [{ "name" => "lane-a", "merge_sha" => merge_commit.strip,
                        "integration_branch" => "project/my-space" }]
        }
      }

    lane_calls = recorded(fake, "lane")
    integrated = lane_calls.last
    assert_json integrated[1],
      {
        "iteration" => { "ordinal" => 1, "name" => "dance" },
        "lane" => { "name" => "lane-a", "repo" => "demo-repo", "base_sha" => lane["base_sha"],
                    "harness" => "pi", "model" => Space::Architect::Harness::DEFAULT_MODEL,
                    "touch_set" => ["feature.rb"],
                    "status" => "integrated" }
      }
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  def test_integrate_bounds_override_lands_in_the_lane_re_emission
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    project, fake, = run_dance(space)
    wt = space.path.join("build", "I01-dance-lane-a", "wt")
    File.write(File.join(wt, "out-of-bounds.txt"), "outside the declared touch set\n")
    capture_io { project.integrate!("dance", lanes: ["lane-a"], accept_bounds_reason: "touch-set glob is the defect") }

    entry = space.data.dig("project", "iterations", 0)
    lane = entry["lanes"].first
    assert_equal "touch-set glob is the defect", lane["bounds_override_reason"]
    lane_calls = recorded(fake, "lane")
    integrated = JSON.parse(lane_calls.last[1])
    assert_equal "touch-set glob is the defect", integrated["lane"]["bounds_override_reason"]
    assert_equal "integrated", integrated["lane"]["status"]
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  # ---- inertness / inviolability --------------------------------------------

  def test_teardown_only_integrate_emits_nothing
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    project, fake, = run_dance(space)
    capture_io { project.integrate!("dance", lanes: ["lane-a"]) }
    fake.calls.clear
    capture_io { project.integrate!("dance", teardown: true) }
    assert_empty fake.calls
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  def test_unconfigured_dance_is_inert
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    fake = RecordingEmitter.new # records nothing when unconfigured — use raw nil-emitter project
    project = Space::Architect::ArchitectProject.new(space: space)
    assert_nil project.emitter

    out, err = capture_io do
      project.new_iteration!("dance")
      project.write_section!("dance", "specification", body: SPEC_BODY)
      project.write_section!("dance", "acceptance-criteria", body: AC_BODY)
      project.freeze!("dance", skip_rehearse_reason: "test")
      project.provision("dance", base: "main")
      File.write(space.path.join("build", "I01-dance-lane-a", "wt", "feature.rb"), "puts 'hi'\n")
      results = project.run_gates("dance", lane: "lane-a")
      project.gate_transcript("dance", results, lane: "lane-a")
      FileUtils.mkdir_p(space.path.join("build", "I01-dance-lane-a"))
      File.write(space.path.join("build", "I01-dance-lane-a", "report.md"), "x\nSTATUS: COMPLETE\n")
      project.transcribe_evidence!("dance", lane: "lane-a")
      project.record_verdict!("dance", decision: "continue", body: "LGTM.")
      project.integrate!("dance", lanes: ["lane-a"])
    end
    assert_empty fake.calls
    # The model-default inform (pre-existing behavior) is the only permitted
    # stderr line; no emission line of any kind may appear.
    refute_includes err + out, "/iterations/ingest/"
    refute_includes err + out, "emission failed"
    refute_includes err + out, "emission skipped"
    refute_includes err + out, "emission off"
    refute_includes err + out, "emission config"
    assert_equal 1, (err + out).lines.grep(/architect\.yaml/).count
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  def test_dead_server_never_blocks_and_reports_once_per_emission
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    closed = TCPServer.new("127.0.0.1", 0)
    dead_port = closed.addr[1]
    closed.close
    dead = Space::Architect::IterationEmission::Emitter.new(
      host: "http://127.0.0.1:#{dead_port}", token: TOKEN, slug: "my-space")

    project = Space::Architect::ArchitectProject.new(space: space, emitter: dead)
    shas = {}
    out, err = capture_io do
      project.new_iteration!("dance")
      project.write_section!("dance", "specification", body: SPEC_BODY)
      project.write_section!("dance", "acceptance-criteria", body: AC_BODY)
      shas[:freeze] = project.freeze!("dance", skip_rehearse_reason: "test")
      project.provision("dance", base: "main")
      File.write(space.path.join("build", "I01-dance-lane-a", "wt", "feature.rb"), "puts 'hi'\n")
      results = project.run_gates("dance", lane: "lane-a")
      shas[:gate] = project.gate_transcript("dance", results, lane: "lane-a")
      FileUtils.mkdir_p(space.path.join("build", "I01-dance-lane-a"))
      File.write(space.path.join("build", "I01-dance-lane-a", "report.md"), "x\nSTATUS: COMPLETE\n")
      shas[:evidence] = project.transcribe_evidence!("dance", lane: "lane-a")[:sha]
      shas[:verdict] = project.record_verdict!("dance", decision: "continue", body: "LGTM.")[:sha]
      shas[:integrate] = project.integrate!("dance", lanes: ["lane-a"]).first[:merge_sha]
    end

    # Every step completed and committed.
    [:freeze, :evidence, :verdict, :integrate].each do |k|
      assert_match(/\A[0-9a-f]{40}\z/, shas[k], "#{k} must still return a real sha")
    end
    refute_nil shas[:gate]

    # freeze + evidence + gate + verdict + integrate(integration, lane) — one
    # emission-failure stderr line each.
    emission_lines = err.lines.select { |l| l.include?("emission failed") }
    assert_equal 6, emission_lines.count
    refute_includes err + out, TOKEN

    # Commits landed: freeze, evidence, verdict, integrate metadata.
    log, = Open3.capture3("git", "-C", dir, "log", "--format=%s")
    assert_includes log, "I01: acceptance criteria"
    assert_includes log, "I01: record freeze sha"
    assert_includes log, "I01: evidence"
    assert_includes log, "I01: verdict"
    assert_includes log, "I01: record integration"
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  def test_emission_bug_never_changes_the_loop_command
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    bomb = Object.new
    bomb.define_singleton_method(:post) { |*_args| raise NoMemoryError, "payload builder blew up" }
    project = Space::Architect::ArchitectProject.new(space: space, emitter: bomb)

    sha, err_out = nil
    out, err = capture_io do
      project.new_iteration!("dance")
      project.write_section!("dance", "specification", body: SPEC_BODY)
      project.write_section!("dance", "acceptance-criteria", body: AC_BODY)
      sha = project.freeze!("dance", skip_rehearse_reason: "test")
    end
    refute_nil sha
    assert_equal 1, err.lines.select { |l| l.include?("emission skipped") }.count
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  # ---- `architect emit` re-derivation ---------------------------------------

  def test_emit_replays_are_byte_identical_to_the_live_payloads
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    project, fake, = run_dance(space)
    capture_io { project.integrate!("dance", lanes: ["lane-a"]) }

    # freeze facet
    replay = project.emission_replays("dance", facet: "freeze")
    assert_equal 1, replay.size
    assert_equal recorded(fake, "freeze").first[1], JSON.generate(replay.first)

    # lane facet — sidecar exists → the gate-time payload, byte-identical
    replay = project.emission_replays("dance", facet: "lane")
    assert_equal 1, replay.size
    gate_time = recorded(fake, "lane").first
    assert_equal gate_time[1], JSON.generate(replay.first)

    # verdict facet
    replay = project.emission_replays("dance", facet: "verdict")
    assert_equal 1, replay.size
    assert_equal recorded(fake, "verdict").first[1], JSON.generate(replay.first)

    # integration facet — byte-identical: the re-derivation recovers each
    # lane's repo MERGE commit from the branch history (second parent == the
    # recorded integrate_sha), the same value the live call posted.
    replay = project.emission_replays("dance", facet: "integration")
    assert_equal 1, replay.size
    assert_equal recorded(fake, "integration").first[1], JSON.generate(replay.first)
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  def test_emit_lane_without_sidecar_replays_the_evidence_payload
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    project, fake, = run_dance(space, run_gate: false)

    replay = project.emission_replays("dance", facet: "lane")
    assert_equal 1, replay.size
    assert_equal recorded(fake, "lane").first[1], JSON.generate(replay.first)
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  def test_emit_lane_filtering
    dir = Dir.mktmpdir("hooks-fixture")
    pin_emission_absent(dir)
    space = create_real_space(dir)
    create_real_repo(dir, "demo-repo")

    project, fake, = run_dance(space, run_gate: false)
    # A second, never-evidenced lane rides the record unfiltered.
    filtered = project.emission_replays("dance", facet: "lane", lane: "lane-a")
    assert_equal 1, filtered.size
    assert_equal "lane-a", filtered.first["lane"]["name"]

    assert_raises(Space::Core::Error) do
      project.emission_replays("dance", facet: "lane", lane: "no-such-lane")
    end
    # Unfiltered: every recorded lane appears exactly once.
    assert_equal fake.calls.count { |m, _| m == "lane" },
                 project.emission_replays("dance", facet: "lane").size
  ensure
    FileUtils.rm_rf(dir) if dir
    restore_emission_config
  end

  # ---- CLI-level `architect emit` ------------------------------------------

  def test_emit_cli_unconfigured_prints_emission_off_and_exits_zero
    setup = temp_env
    with_env(setup[:env]) do
      space_invoke("init")
      space_path = create_real_space(File.join(setup[:env]["HOME"])).path.to_s
      create_real_repo(space_path, "demo-repo")
      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "dance")
        invoke("section", "dance", "specification", "--body", SPEC_BODY)
        invoke("section", "dance", "acceptance-criteria", "--body", AC_BODY)
        invoke("freeze", "dance", "--skip-rehearse", "test emission dance")

        out, err = invoke("emit", "dance")
        assert_empty err
        assert_equal 2, out.lines.grep(/emission off \(unconfigured\)/).count
        assert_equal 2, out.lines.grep(/nothing to emit/).count
        assert_equal 0, Space::Architect::CLI.call(["emit", "dance"], StringIO.new, StringIO.new)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_emit_cli_dead_server_exit_one
    setup = temp_env
    with_env(setup[:env]) do
      space_invoke("init")
      space_path = create_real_space(File.join(setup[:env]["HOME"])).path.to_s
      create_real_repo(space_path, "demo-repo")
      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "dance")
        invoke("section", "dance", "specification", "--body", SPEC_BODY)
        invoke("section", "dance", "acceptance-criteria", "--body", AC_BODY)
        invoke("freeze", "dance", "--skip-rehearse", "test emission dance")

        closed = TCPServer.new("127.0.0.1", 0)
        dead_port = closed.addr[1]
        closed.close
        code = nil
        out = err = nil
        with_env("SPACE_ARCHITECT_EMISSION_HOST" => "http://127.0.0.1:#{dead_port}",
                 "SPACE_ARCHITECT_EMISSION_TOKEN" => TOKEN) do
          oo, ee = StringIO.new, StringIO.new
          _global_err, emission_err = capture_io do
            code = Space::Architect::CLI.call(["emit", "dance"], oo, ee)
          end
          out = oo.string
          err = emission_err
        end
        assert_equal 1, code, "any POST failure must exit 1"
        assert_includes out, "emission failed (freeze)"
        assert_includes err, "emission failed after"
        refute_includes err, TOKEN
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_emit_cli_facet_selection_and_nothing_to_emit
    setup = temp_env
    with_env(setup[:env]) do
      space_invoke("init")
      space_path = create_real_space(File.join(setup[:env]["HOME"])).path.to_s
      create_real_repo(space_path, "demo-repo")
      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "dance")

        out, _err = invoke("emit", "dance")
        assert_equal 4, out.lines.grep(/nothing to emit/).count

        out, _err = invoke("emit", "dance", "--facet", "freeze")
        assert_match(/nothing to emit \(freeze\)/, out)
        refute_match(/lane/, out)

        out, err = invoke("emit", "dance", "--facet", "bogus")
        assert_match(/unknown facet/, err)
        assert_equal 1, Space::Architect::CLI.call(["emit", "dance", "--facet", "bogus"], StringIO.new, StringIO.new)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end
end

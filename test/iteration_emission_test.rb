# frozen_string_literal: true

require_relative "test_helper"
require "socket"
require "json"
require "yaml"

# I16 — the emission layer: config resolution, the best-effort client against
# a REAL local TCP server (not a mock object), the payload builders, and the
# ```rulings parser. Every token-discipline assertion pins that the bearer
# never reaches any captured output or exception text.
class IterationEmissionTest < Space::ArchitectTest
  TOKEN = "sat_test_#{SecureRandom.hex(8)}"

  # ---- a test-owned minimal HTTP server on an ephemeral port ---------------

  def start_test_server(statuses) # rubocop:disable Lint/UselessAssignment — statuses consumed by handler below
    requests = []
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        sock = server.accept
        Thread.new(sock) do |client|
          request = read_http_request(client)
          if request
            requests << request
            status = requests.size <= statuses.size ? statuses[requests.size - 1] : statuses.last
            body = status.is_a?(Array) ? status[1] : "{\"ok\":true}"
            code = status.is_a?(Array) ? status[0] : status
            client.write("HTTP/1.1 #{code} X\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          end
          client.close
        end
      end
    rescue IOError, Errno::EBADF
      nil
    end
    [requests, server, port, thread]
  end

  def read_http_request(client)
    head = []
    loop do
      line = client.gets
      return nil unless line
      break if line.strip.empty?

      head << line.strip
    end
    method, path, = head.first.split(" ", 3)
    headers = {}
    head.drop(1).each do |line|
      key, value = line.split(":", 2)
      headers[key.strip] = value.strip
    end
    body = headers["Content-Length"].to_i.positive? ? client.read(headers["Content-Length"].to_i) : ""
    { method: method, path: path, headers: headers, body: body }
  end

  def stop_test_server(server, thread)
    server.close
    thread.join(1)
  end

  def emitter(port, slug: "my-space")
    Space::Architect::IterationEmission::Emitter.new(
      host: "http://127.0.0.1:#{port}", token: TOKEN, slug: slug)
  end

  FREEZE_PAYLOAD = {
    "iteration" => { "ordinal" => 1, "name" => "dance", "freeze_sha" => "abc", "branch" => "main", "status" => "frozen" },
    "gates" => [{ "id" => "G0", "ac" => "AC1", "cmd" => "true", "expect" => { "exit_code" => 0 } }]
  }.freeze

  # ---- config resolution -----------------------------------------------------

  def with_emission_env(vars)
    vars = { "SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => File.join(Dir.tmpdir, "emission-absent-#{rand(1e6)}.yaml") }.merge(vars)
    with_env(vars) { yield }
  end

  def test_unconfigured_resolves_nil_and_stays_silent
    out, err = capture_io do
      with_emission_env({}) do
        assert_nil Space::Architect::IterationEmission.emitter_for(fake_space)
      end
    end
    assert_empty out
    assert_empty err
  end

  def test_file_config_resolves_emitter
    config = write_config("host" => "http://example.test", "token" => "sat_file")
    with_emission_env("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => config) do
      em = Space::Architect::IterationEmission.emitter_for(fake_space)
      assert_instance_of Space::Architect::IterationEmission::Emitter, em
      assert_equal "http://example.test", em.host
      assert_equal "sat_file", em.token
      assert_equal "my-space", em.slug
    end
  end

  def test_env_beats_file_per_field
    config = write_config("host" => "http://file.test", "token" => "sat_file", "disabled" => false)
    with_emission_env("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => config,
                      "SPACE_ARCHITECT_EMISSION_HOST" => "http://env.test") do
      em = Space::Architect::IterationEmission.emitter_for(fake_space)
      assert_equal "http://env.test", em.host
      assert_equal "sat_file", em.token
    end
    with_emission_env("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => config,
                      "SPACE_ARCHITECT_EMISSION_TOKEN" => "sat_env") do
      assert_equal "sat_env", Space::Architect::IterationEmission.emitter_for(fake_space).token
      assert_equal "http://file.test", Space::Architect::IterationEmission.emitter_for(fake_space).host
    end
  end

  def test_disabled_knob_mutes_both_ways
    config = write_config("host" => "http://file.test", "token" => "sat_file", "disabled" => true)
    with_emission_env("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => config) do
      assert_nil Space::Architect::IterationEmission.emitter_for(fake_space)
    end
    # env beats the file both ways: present non-mute value unmutes a muted file.
    with_emission_env("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => config,
                      "SPACE_ARCHITECT_EMISSION_DISABLED" => "0") do
      assert_instance_of Space::Architect::IterationEmission::Emitter,
                         Space::Architect::IterationEmission.emitter_for(fake_space)
    end
    # "1"/"true" mutes a configured env.
    with_emission_env("SPACE_ARCHITECT_EMISSION_HOST" => "http://env.test",
                      "SPACE_ARCHITECT_EMISSION_TOKEN" => "sat_env",
                      "SPACE_ARCHITECT_EMISSION_DISABLED" => "1") do
      assert_nil Space::Architect::IterationEmission.emitter_for(fake_space)
    end
    with_emission_env("SPACE_ARCHITECT_EMISSION_HOST" => "http://env.test",
                      "SPACE_ARCHITECT_EMISSION_TOKEN" => "sat_env",
                      "SPACE_ARCHITECT_EMISSION_DISABLED" => "true") do
      assert_nil Space::Architect::IterationEmission.emitter_for(fake_space)
    end
    with_emission_env("SPACE_ARCHITECT_EMISSION_HOST" => "http://env.test",
                      "SPACE_ARCHITECT_EMISSION_TOKEN" => "sat_env",
                      "SPACE_ARCHITECT_EMISSION_DISABLED" => "off") do
      assert_instance_of Space::Architect::IterationEmission::Emitter,
                         Space::Architect::IterationEmission.emitter_for(fake_space)
    end
  end

  def test_missing_host_or_token_is_unconfigured
    config = write_config("host" => "http://file.test")
    with_emission_env("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => config) do
      assert_nil Space::Architect::IterationEmission.emitter_for(fake_space)
    end
    with_emission_env("SPACE_ARCHITECT_EMISSION_HOST" => "http://env.test") do
      assert_nil Space::Architect::IterationEmission.emitter_for(fake_space)
    end
  end

  def test_malformed_file_is_inert_with_one_stderr_line_naming_the_path
    path = File.join(Dir.tmpdir, "emission-malformed-#{rand(1e6)}.yaml")
    File.write(path, "host: [unclosed\n\ttoken ::::")
    out, err = capture_io do
      with_emission_env("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => path) do
        assert_nil Space::Architect::IterationEmission.emitter_for(fake_space)
      end
    end
    assert_empty out
    assert_equal 1, err.lines.count
    assert_includes err, path
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_unreadable_file_is_inert_with_one_stderr_line
    skip "running as root defeats permission bits" if Process.uid.zero?
    path = File.join(Dir.tmpdir, "emission-locked-#{rand(1e6)}.yaml")
    File.write(path, "host: x\n")
    File.chmod(0o000, path)
    out, err = capture_io do
      with_emission_env("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => path) do
        assert_nil Space::Architect::IterationEmission.emitter_for(fake_space)
      end
    end
    assert_empty out
    assert_equal 1, err.lines.count
    assert_includes err, path
  ensure
    File.chmod(0o644, path) if path && File.exist?(path)
    File.delete(path) if path && File.exist?(path)
  end

  def test_global_path_follows_the_routing_pattern
    with_env("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => "/tmp/pinned.yaml") do
      assert_equal Pathname.new("/tmp/pinned.yaml"),
                   Space::Architect::IterationEmission.global_path
    end
    with_env("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => nil) do
      assert_equal Pathname.new("~/.config/space-architect/emission.yaml").expand_path,
                   Space::Architect::IterationEmission.global_path
    end
  end

  def test_slug_follows_the_in_house_rule_with_id_fallback
    assert_equal "my-space", Space::Architect::IterationEmission.slug_for(fake_space)
    bare = Struct.new(:title, :data).new(nil, { "id" => "20260619-x" })
    assert_equal "20260619-x", Space::Architect::IterationEmission.slug_for(bare)
    punct = Struct.new(:title, :data).new("My  Space!", { "id" => "id1" })
    assert_equal "my-space", Space::Architect::IterationEmission.slug_for(punct)
  end

  # ---- the client against a real TCP server ---------------------------------

  def test_freeze_post_exact_request_and_result
    requests, server, port, thread = start_test_server([200])
    result = emitter(port).post("freeze", FREEZE_PAYLOAD)
    stop_test_server(server, thread)

    req = requests.first
    assert_equal "POST", req[:method]
    assert_equal "/iterations/ingest/freeze", req[:path]
    assert_equal "application/json", req[:headers]["Content-Type"]
    assert_equal "Bearer #{TOKEN}", req[:headers]["Authorization"]
    assert_equal "my-space", req[:headers]["X-Space-Slug"]
    assert_equal JSON.generate(FREEZE_PAYLOAD), req[:body]
    assert_equal 200, result[:status]
    assert_equal({ "ok" => true }, result[:body])
  end

  def test_host_trailing_slashes_stripped
    requests, server, port, thread = start_test_server([200])
    em = Space::Architect::IterationEmission::Emitter.new(
      host: "http://127.0.0.1:#{port}/", token: TOKEN, slug: "s")
    em.post("freeze", FREEZE_PAYLOAD)
    stop_test_server(server, thread)
    assert_equal "/iterations/ingest/freeze", requests.first[:path]
  end

  def test_5xx_retried_then_success
    requests, server, port, thread = start_test_server([500, 200])
    result = emitter(port).post("freeze", FREEZE_PAYLOAD)
    stop_test_server(server, thread)
    assert_equal 2, requests.size
    assert_equal 200, result[:status]
  end

  def test_4xx_never_retried
    requests, server, port, thread = start_test_server([422])
    out, err = capture_io do
      assert_nil emitter(port).post("freeze", FREEZE_PAYLOAD)
    end
    stop_test_server(server, thread)
    assert_equal 1, requests.size
    assert_equal 1, err.lines.count
    assert_match(%r{/iterations/ingest/freeze: emission failed after 2 attempt\(s\): status 422}, err)
    assert_empty out
  end

  def test_5xx_twice_reports_once_with_bounded_excerpt
    long = "x" * 500
    requests, server, port, thread = start_test_server([[500, long], [500, long]])
    out, err = capture_io do
      assert_nil emitter(port).post("freeze", FREEZE_PAYLOAD)
    end
    stop_test_server(server, thread)
    assert_equal 2, requests.size
    assert_equal 1, err.lines.count
    assert_includes err, "status 500 — #{'x' * 200}"
    refute_includes err, ("x" * 201)
    assert_empty out
  end

  def test_refused_connection_two_attempts_then_one_stderr_line
    closed = TCPServer.new("127.0.0.1", 0)
    port = closed.addr[1]
    closed.close
    out, err = capture_io do
      assert_nil emitter(port).post("lane", { "iteration" => { "ordinal" => 1, "name" => "n" }, "lane" => { "name" => "l" } })
    end
    assert_empty out
    assert_equal 1, err.lines.count
    assert_match(%r{/iterations/ingest/lane: emission failed after 2 attempt\(s\): }, err)
  end

  def test_token_and_payload_never_in_any_failure_output
    marker = "PAYLOAD-MARKER-#{rand(1e6)}"
    payload = { "iteration" => { "ordinal" => 1, "name" => marker }, "lane" => { "name" => marker } }
    requests, server, port, thread = start_test_server([[500, "server says no"], [500, "server says no"]])
    out, err = capture_io do
      assert_nil emitter(port).post("lane", payload)
    end
    stop_test_server(server, thread)

    closed = TCPServer.new("127.0.0.1", 0)
    dead_port = closed.addr[1]
    closed.close
    out2, err2 = capture_io do
      assert_nil emitter(dead_port).post("lane", payload)
    end

    [out + err, out2 + err2].each do |captured|
      refute_includes captured, TOKEN
      refute_includes captured, marker
    end
    assert_empty requests.map { |r| r[:body] }.select { |b| b.include?(TOKEN) }
  end

  def test_freeze_tuning_constants_are_frozen
    assert_equal 2, Space::Architect::IterationEmission::OPEN_TIMEOUT
    assert_equal 5, Space::Architect::IterationEmission::READ_TIMEOUT
    assert_equal 2, Space::Architect::IterationEmission::MAX_ATTEMPTS
  end

  # ---- payload builders ------------------------------------------------------

  def test_map_gate_omits_nil_fields_and_empty_expect_entirely
    mapped = Space::Architect::IterationEmission.map_gate(
      "id" => "G0", "ac" => "AC1", "cmd" => "true", "cwd" => "repos/r",
      "timeout" => 30, "expect" => { "exit_code" => 0 })
    assert_equal({ "id" => "G0", "ac" => "AC1", "cmd" => "true", "cwd" => "repos/r",
                   "timeout" => 30, "expect" => { "exit_code" => 0 } }, mapped)

    bare = Space::Architect::IterationEmission.map_gate("id" => "G1", "ac" => "AC1", "cmd" => "true")
    assert_equal({ "id" => "G1", "ac" => "AC1", "cmd" => "true" }, bare)

    empty = Space::Architect::IterationEmission.map_gate(
      "id" => "G2", "ac" => "AC1", "cmd" => "true", "expect" => {})
    assert_equal({ "id" => "G2", "ac" => "AC1", "cmd" => "true" }, empty)
  end

  def test_build_lane_omits_nil_and_empty_scalars_and_absent_children
    record = { "name" => "emitter", "repo" => "demo", "base_sha" => "b1",
               "model" => nil, "harness" => "pi", "effort" => "", "touch_set" => [] }
    built = Space::Architect::IterationEmission.build_lane(
      ordinal: 1, name: "dance", lane_record: record, status: "complete")
    assert_equal(
      { "iteration" => { "ordinal" => 1, "name" => "dance" },
        "lane" => { "name" => "emitter", "repo" => "demo", "base_sha" => "b1",
                    "harness" => "pi", "status" => "complete" } },
      built)
  end

  def test_map_gate_result_omits_empty_reason
    result = Space::Architect::IterationEmission.map_gate_result(
      { gate_id: "G0", status: :pass, reason: "" }, "transcript text")
    assert_equal({ "gate_id" => "G0", "status" => "pass", "transcript" => "transcript text" }, result)
    failed = Space::Architect::IterationEmission.map_gate_result(
      { gate_id: "G1", status: :fail, reason: "boom" }, "t")
    assert_equal "boom", failed["reason"]
  end

  def test_map_sidecar_gate_carries_every_mirror_key
    entry = Space::Architect::IterationEmission.map_sidecar_gate(
      id: "G0", status: :pass, reason: "", stdout: "out", stderr: "",
      exit_code: 0, cmd: "true", dir: Pathname.new("/tmp/wt"))
    assert_equal({ "gate_id" => "G0", "status" => "pass", "reason" => "", "stdout" => "out",
                   "stderr" => "", "exit_code" => 0, "cmd" => "true", "dir" => "/tmp/wt" }, entry)
  end

  # ---- the ```rulings block --------------------------------------------------

  def test_rulings_valid_block_rides_the_emission_verbatim
    body = <<~BODY
      Decision text.
      ```rulings
      ac_rulings:
        - ac: AC1
          ruling: PASS
          note: gates green
        - ac: AC2
          ruling: MODIFY
      phase0_resolutions:
        - topic: routing drift
          lane: emitter
          resolution: took the CLI path
        - topic: lint refusal
      ```
      Trailing prose.
    BODY
    out, err = capture_io do
      rulings = Space::Architect::IterationEmission.parse_rulings(body)
      assert_equal(
        { ac_rulings: [{ "ac" => "AC1", "ruling" => "PASS", "note" => "gates green" },
                       { "ac" => "AC2", "ruling" => "MODIFY" }],
          phase0_resolutions: [{ "topic" => "routing drift", "lane" => "emitter", "resolution" => "took the CLI path" },
                               { "topic" => "lint refusal" }] },
        rulings)
    end
    assert_empty err
    assert_empty out
  end

  def test_rulings_invalid_entries_dropped_with_named_stderr
    body = <<~BODY
      ```rulings
      ac_rulings:
        - ac: AC1
          ruling: PASS
        - ruling: MISSING AC
      phase0_resolutions:
        - lane: no topic
      ```
    BODY
    out, err = capture_io do
      rulings = Space::Architect::IterationEmission.parse_rulings(body)
      assert_equal({ ac_rulings: [{ "ac" => "AC1", "ruling" => "PASS" }], phase0_resolutions: [] }, rulings)
    end
    assert_empty out
    assert_equal 2, err.lines.count
    assert_includes err, "ac_rulings"
    assert_includes err, "phase0_resolutions"
  end

  def test_rulings_malformed_yaml_warns_and_decides_only
    body = "```rulings\nac_rulings: [unclosed\n```\n"
    out, err = capture_io do
      assert_equal({}, Space::Architect::IterationEmission.parse_rulings(body))
    end
    assert_empty out
    assert_equal 1, err.lines.count
    assert_includes err, "malformed"
  end

  def test_rulings_no_block_is_silent_decision_only
    out, err = capture_io do
      assert_equal({}, Space::Architect::IterationEmission.parse_rulings("just prose\n"))
    end
    assert_empty out
    assert_empty err
  end

  def test_rulings_block_shape_mismatch_warns_and_drops
    body = "```rulings\n- just\n- a list\n```\n"
    out, err = capture_io do
      assert_equal({}, Space::Architect::IterationEmission.parse_rulings(body))
    end
    assert_empty out
    assert_equal 1, err.lines.count
  end

  # ---- fixture helpers -------------------------------------------------------

  def write_config(hash)
    path = File.join(Dir.tmpdir, "emission-config-#{rand(1e6)}.yaml")
    File.write(path, YAML.dump(hash))
    path
  end

  def fake_space
    Struct.new(:title, :data).new("My Space", { "id" => "id-1" })
  end
end

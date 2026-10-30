# frozen_string_literal: true

require_relative "test_helper"
require "socket"
require "json"
require "yaml"

# I11 — the phase ping: the PHASE_KINDS vocabulary + build_phase payload (the
# frozen phase contract), the phase mouth against a REAL local TCP server, and
# the `architect ping` command's frozen surface (unknown phase/iteration,
# unconfigured inertness, success line, dead-server-never-fails + token
# discipline). The emitter-level patterns are iteration_emission_test.rb's and
# the CLI-level patterns are iteration_emission_hooks_test.rb's — duplicated
# here because test_helper.rb and both pre-existing test files sit outside
# this lane's declared touch set (the file-local duplication precedent).
class PhasePingTest < Space::ArchitectTest
  TOKEN = "sat_ping_#{SecureRandom.hex(8)}"

  # ---- the frozen phase contract -------------------------------------------

  def test_phase_kinds_are_the_frozen_vocabulary
    assert_equal %w[spec-launched builders-settled judge-running],
                 Space::Architect::IterationEmission::PHASE_KINDS
    assert_predicate Space::Architect::IterationEmission::PHASE_KINDS, :frozen?
  end

  def test_mouths_gain_phase_with_the_frozen_four_intact
    assert_equal %w[freeze lane verdict integration phase],
                 Space::Architect::IterationEmission::MOUTHS
  end

  def test_build_phase_carries_contract_keys_only
    built = Space::Architect::IterationEmission.build_phase(
      ordinal: 3, name: "dance", kind: "spec-launched")
    assert_equal(
      { "iteration" => { "ordinal" => 3, "name" => "dance" },
        "phase" => { "kind" => "spec-launched" } },
      built)
    # The iteration hash carries ONLY ordinal + name on the ping path — no
    # freeze_sha/branch/status optionals, those belong to the other mouths.
    assert_equal %w[ordinal name], built["iteration"].keys
    assert_equal %w[kind], built["phase"].keys
  end

  def test_build_phase_omits_note_when_nil_or_empty
    nil_note = Space::Architect::IterationEmission.build_phase(
      ordinal: 1, name: "dance", kind: "builders-settled", note: nil)
    assert_equal({ "iteration" => { "ordinal" => 1, "name" => "dance" },
                   "phase" => { "kind" => "builders-settled" } }, nil_note)

    empty_note = Space::Architect::IterationEmission.build_phase(
      ordinal: 1, name: "dance", kind: "builders-settled", note: "")
    refute_includes empty_note["phase"], "note"

    carried = Space::Architect::IterationEmission.build_phase(
      ordinal: 1, name: "dance", kind: "judge-running", note: "judge up")
    assert_equal("judge up", carried["phase"]["note"])
  end

  # ---- the phase mouth against a real TCP server ----------------------------

  def test_phase_mouth_post_exact_request_and_result
    requests, server, port, thread = start_test_server([200])
    payload = Space::Architect::IterationEmission.build_phase(
      ordinal: 2, name: "dance", kind: "judge-running", note: "judge up")
    result = emitter(port).post("phase", payload)
    stop_test_server(server, thread)

    req = requests.first
    assert_equal "POST", req[:method]
    assert_equal "/iterations/ingest/phase", req[:path]
    assert_equal "application/json", req[:headers]["Content-Type"]
    assert_equal "Bearer #{TOKEN}", req[:headers]["Authorization"]
    assert_equal "my-space", req[:headers]["X-Space-Slug"]
    assert_equal JSON.generate(payload), req[:body]
    assert_equal 200, result[:status]
    assert_equal({ "ok" => true }, result[:body])
  end

  # ---- the `architect ping` command ------------------------------------------
  #
  # CLI fixture: a real space with one recorded iteration ("dance", ordinal 1),
  # built through the real CLI in a temp HOME — the iteration_emission_hooks
  # CLI-fixture shape.

  def create_real_space(base_dir)
    dir = File.join(base_dir, "spaces", "ping-space")
    FileUtils.mkdir_p(File.join(dir, "architecture"))
    FileUtils.mkdir_p(File.join(dir, "repos"))
    FileUtils.mkdir_p(File.join(dir, "tmp"))

    data = {
      "version" => 1, "id" => "ping-space", "title" => "My Space", "status" => "active",
      "created_at" => "2026-06-19T00:00:00Z", "updated_at" => "2026-06-19T00:00:00Z",
      "repos" => [], "notes" => [], "tickets" => [], "tags" => []
    }
    yaml = YAML.dump(data)
    File.write(File.join(dir, "space.yaml"), yaml)
    FileUtils.cp_r(File.join(Space::GitFixtureTemplate.space_dir(yaml), ".git"), dir)
    dir
  end

  def space_with_iteration
    setup = temp_env
    space_path = nil
    with_env(setup[:env]) do
      space_invoke("init")
      space_path = create_real_space(File.join(setup[:env]["HOME"]))
      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "dance")
      end
      yield setup, space_path
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # One CLI ping invocation with $stderr captured around it — the Emitter
  # reports failures on $stderr, outside the CLI's out/err streams.
  # Returns [out, err, exit_code].
  def ping_cli(*argv)
    oo, ee = StringIO.new, StringIO.new
    code = nil
    _stdout, stderr = capture_io do
      code = Space::Architect::CLI.call(["ping", *argv], oo, ee)
    end
    [oo.string, stderr, code]
  end

  def test_ping_unknown_phase_errors_naming_the_known_set
    space_with_iteration do |_setup, space_path|
      Dir.chdir(space_path) do
        out, err = invoke("ping", "nosuch-iteration", "bogus")
        assert_empty out
        assert_includes err, "unknown phase 'bogus'"
        assert_includes err, "spec-launched, builders-settled, judge-running"
        # Validation precedes space resolution: the phase error wins even
        # though the iteration name is unknown too.
        refute_includes err, "not recorded in space.yaml"
        assert_equal 1, Space::Architect::CLI.call(
          ["ping", "nosuch-iteration", "bogus"], StringIO.new, StringIO.new)
      end
    end
  end

  def test_ping_unknown_iteration_is_the_standard_not_found_error
    space_with_iteration do |_setup, space_path|
      Dir.chdir(space_path) do
        out, err = invoke("ping", "nosuch", "spec-launched")
        assert_empty out
        assert_includes err, "Iteration 'nosuch' not recorded in space.yaml — run `architect new nosuch` first"
        assert_equal 1, Space::Architect::CLI.call(
          ["ping", "nosuch", "spec-launched"], StringIO.new, StringIO.new)
      end
    end
  end

  def test_ping_unconfigured_is_one_inert_stdout_line_and_exit_zero
    space_with_iteration do |setup, space_path|
      Dir.chdir(space_path) do
        out, err, code = nil, nil, nil
        with_env("SPACE_ARCHITECT_GLOBAL_CONFIG" => File.join(setup[:root], "absent-routing.yaml"),
                 "SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => File.join(setup[:root], "absent-emission.yaml")) do
          out, err, code = ping_cli("dance", "spec-launched")
        end
        assert_equal 0, code
        assert_equal "emission off (unconfigured)\n", out
        assert_empty err
      end
    end
  end

  def test_ping_success_posts_the_frozen_phase_contract
    requests, server, port, thread = start_test_server([200, 200])
    space_with_iteration do |setup, space_path|
      Dir.chdir(space_path) do
        with_env("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => File.join(setup[:root], "absent-emission.yaml"),
                 "SPACE_ARCHITECT_EMISSION_HOST" => "http://127.0.0.1:#{port}",
                 "SPACE_ARCHITECT_EMISSION_TOKEN" => TOKEN) do
          out, err, code = ping_cli("dance", "judge-running", "--note", "judge up")
          assert_equal 0, code
          assert_empty err
          assert_equal "pinged dance judge-running → 200\n", out

          out, err, code = ping_cli("dance", "spec-launched")
          assert_equal 0, code
          assert_empty err
          assert_equal "pinged dance spec-launched → 200\n", out
        end
      end
    end
    stop_test_server(server, thread)

    assert_equal 2, requests.size
    req = requests.first
    assert_equal "POST", req[:method]
    assert_equal "/iterations/ingest/phase", req[:path]
    assert_equal "Bearer #{TOKEN}", req[:headers]["Authorization"]
    assert_equal "my-space", req[:headers]["X-Space-Slug"]
    assert_equal(
      { "iteration" => { "ordinal" => 1, "name" => "dance" },
        "phase" => { "kind" => "judge-running", "note" => "judge up" } },
      JSON.parse(req[:body]))
    assert_equal(
      { "iteration" => { "ordinal" => 1, "name" => "dance" },
        "phase" => { "kind" => "spec-launched" } },
      JSON.parse(requests.last[:body]))
  end

  def test_ping_dead_server_never_fails_the_step_and_hides_the_token
    closed = TCPServer.new("127.0.0.1", 0)
    dead_port = closed.addr[1]
    closed.close

    space_with_iteration do |setup, space_path|
      Dir.chdir(space_path) do
        out, err, code = nil, nil, nil
        with_env("SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG" => File.join(setup[:root], "absent-emission.yaml"),
                 "SPACE_ARCHITECT_EMISSION_HOST" => "http://127.0.0.1:#{dead_port}",
                 "SPACE_ARCHITECT_EMISSION_TOKEN" => TOKEN) do
          out, err, code = ping_cli("dance", "builders-settled", "--note", "all lanes tended")
        end
        assert_equal 0, code, "a POST failure must NEVER fail the ping — quieter than emit"
        assert_empty out, "a failed ping prints nothing on stdout"
        assert_equal 1, err.lines.count
        assert_match(%r{/iterations/ingest/phase: emission failed after 2 attempt\(s\)}, err)
        refute_includes out + err, TOKEN
        refute_includes out + err, "all lanes tended", "the payload is never echoed"
      end
    end
  end

  # ---- test-owned minimal HTTP server (iteration_emission_test.rb's pattern)

  def start_test_server(statuses)
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
end

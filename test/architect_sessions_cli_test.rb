# frozen_string_literal: true

require_relative "test_helper"
require "socket"
require "json"
require "fileutils"
require "tmpdir"

# CLI-level tests for `architect sessions sync|agent install|agent uninstall|agent status`,
# exercised end-to-end via invoke() — same TCP-stub pattern as architect_jobs_cli_test.rb
# for `sync`, and the same Launchd::Agent.new-stubbing pattern as
# test/space_src/cli/daemon_test.rb for `agent` (no live launchctl in tests, per AC5).
class ArchitectSessionsCLITest < Space::ArchitectTest
  Net_HTTP_STATUS = {200 => "OK", 201 => "Created", 401 => "Unauthorized", 422 => "Unprocessable Entity"}.freeze

  def start_stub(responses)
    tcp_server = TCPServer.new("127.0.0.1", 0)
    port = tcp_server.addr[1]
    requests = []

    server_task = Async do
      responses.each do |response|
        socket = tcp_server.accept
        request_line = socket.gets
        method, path, = request_line.split(" ")
        headers = {}
        while (line = socket.gets) && !line.chomp.empty?
          key, value = line.chomp.split(": ", 2)
          headers[key.downcase] = value
        end
        content_length = headers["content-length"].to_i
        body = content_length.positive? ? socket.read(content_length) : ""
        requests << {method: method, path: path, headers: headers, body: body}
        socket.write(response)
        socket.close
      end
    end

    [port, requests, server_task, tcp_server]
  end

  def json_response(status, body)
    payload = JSON.generate(body)
    "HTTP/1.1 #{status} #{Net_HTTP_STATUS[status]}\r\ncontent-type: application/json\r\ncontent-length: #{payload.bytesize}\r\nconnection: close\r\n\r\n#{payload}"
  end

  def write_session_file(dir, *segments, content: "{}\n")
    path = File.join(dir, *segments)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    old = Time.now - 3600
    File.utime(old, old, path)
    path
  end

  # ---- `sessions sync` ----

  # (a) `sessions sync` scans the pi/claude roots, uploads a new file with Bearer
  # auth + multipart per the wire contract, and reports it via the state file.
  def test_sessions_sync_uploads_new_file_and_records_cursor
    setup = temp_env
    with_env(setup[:env]) do
      Dir.mktmpdir("sessions-cli-test") do |root|
        pi_root = File.join(root, "pi")
        claude_root = File.join(root, "claude")
        state_file = File.join(root, "state.yaml")
        path = write_session_file(pi_root, "proj", "20260101T000000_sess-one.jsonl")

        Sync do
          port, requests, server_task, tcp_server = start_stub([
            json_response(201, {conversation_id: 5, action: "created"})
          ])

          out, err = invoke("sessions", "sync",
            "--host", "http://127.0.0.1:#{port}", "--token", "secret-token",
            "--state-file", state_file, "--pi-root", pi_root, "--claude-root", claude_root)
          server_task.wait
          tcp_server.close

          assert_empty err
          assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
          assert_equal "POST",           requests[0][:path] && requests[0][:method]
          assert_equal "/conversations", requests[0][:path]
          assert_equal "Bearer secret-token", requests[0][:headers]["authorization"]
          assert_match(/conversation\[session_id\]/, requests[0][:body])
          assert_match(/sess-one/, requests[0][:body])
          assert_match(/uploaded: #{Regexp.escape(path)}/, out)

          cursor = Space::Architect::SessionSync::Cursor.load(state_file)
          refute_nil cursor[path]
        end
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (b) a second sync pass with the same (unchanged) file makes no HTTP request at all.
  def test_sessions_sync_skips_unchanged_file_on_second_pass
    setup = temp_env
    with_env(setup[:env]) do
      Dir.mktmpdir("sessions-cli-test") do |root|
        pi_root = File.join(root, "pi")
        claude_root = File.join(root, "claude")
        state_file = File.join(root, "state.yaml")
        write_session_file(claude_root, "proj", "sess-two.jsonl")

        Sync do
          port, _requests, server_task, tcp_server = start_stub([
            json_response(201, {conversation_id: 1, action: "created"})
          ])
          invoke("sessions", "sync", "--host", "http://127.0.0.1:#{port}", "--token", "tok",
            "--state-file", state_file, "--pi-root", pi_root, "--claude-root", claude_root)
          server_task.wait
          tcp_server.close
        end

        Sync do
          port, requests, server_task, tcp_server = start_stub([])
          out, _err = invoke("sessions", "sync", "--host", "http://127.0.0.1:#{port}", "--token", "tok",
            "--state-file", state_file, "--pi-root", pi_root, "--claude-root", claude_root)
          server_task.stop
          tcp_server.close

          assert_empty requests
          assert_match(/skipped/, out)
          assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
        end
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (c) a failed upload (422) is reported and the command exits non-zero.
  def test_sessions_sync_exits_nonzero_on_upload_failure
    setup = temp_env
    with_env(setup[:env]) do
      Dir.mktmpdir("sessions-cli-test") do |root|
        pi_root = File.join(root, "pi")
        claude_root = File.join(root, "claude")
        state_file = File.join(root, "state.yaml")
        write_session_file(pi_root, "proj", "20260101T000000_sess-three.jsonl")

        Sync do
          port, _requests, server_task, tcp_server = start_stub([
            json_response(422, {errors: ["session_id can't be blank"]})
          ])
          out, _err = invoke("sessions", "sync", "--host", "http://127.0.0.1:#{port}", "--token", "tok",
            "--state-file", state_file, "--pi-root", pi_root, "--claude-root", claude_root)
          server_task.wait
          tcp_server.close

          assert_match(/failed/, out)
          refute_equal 0, Space::Architect::CLI.last_outcome&.exit_code
        end
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (d) --dry-run makes no HTTP request and does not write the cursor file.
  def test_sessions_sync_dry_run_makes_no_request_and_no_cursor
    setup = temp_env
    with_env(setup[:env]) do
      Dir.mktmpdir("sessions-cli-test") do |root|
        pi_root = File.join(root, "pi")
        claude_root = File.join(root, "claude")
        state_file = File.join(root, "state.yaml")
        write_session_file(pi_root, "proj", "20260101T000000_sess-four.jsonl")

        Sync do
          port, requests, server_task, tcp_server = start_stub([])
          out, _err = invoke("sessions", "sync", "--host", "http://127.0.0.1:#{port}", "--token", "tok",
            "--state-file", state_file, "--pi-root", pi_root, "--claude-root", claude_root, "--dry-run")
          server_task.stop
          tcp_server.close

          assert_empty requests
          assert_match(/would_upload/, out)
          refute File.exist?(state_file)
        end
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (e) --host/--token are required.
  def test_sessions_sync_requires_host_and_token
    setup = temp_env
    with_env(setup[:env]) do
      _out, err = invoke("sessions", "sync", "--token", "tok")
      refute_equal 0, Space::Architect::CLI.last_outcome&.exit_code
      assert_match(/host/i, err)
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ---- `sessions agent install|uninstall|status` ----

  # Stub Space::Src::Launchd::Agent so no live launchctl is ever invoked
  # (mirrors test/space_src/cli/daemon_test.rb's stub_agent).
  def stub_agent(install_result: nil, uninstall_result: nil, status_result: nil)
    fake_class = Class.new do
      attr_reader :calls, :install_result, :uninstall_result, :status_result

      def initialize(install_result:, uninstall_result:, status_result:)
        @calls = []
        @install_result = install_result
        @uninstall_result = uninstall_result
        @status_result = status_result
      end

      def install(plist_path)
        @calls << [:install, plist_path]
        @install_result
      end

      def uninstall
        @calls << [:uninstall]
        @uninstall_result
      end

      def status
        @calls << [:status]
        @status_result
      end
    end

    fake = fake_class.new(
      install_result: install_result || Dry::Monads::Success(""),
      uninstall_result: uninstall_result || Dry::Monads::Success(""),
      status_result: status_result || Dry::Monads::Success({loaded: false, running: false, pid: nil, last_exit: nil})
    )
    agent_class = Space::Src::Launchd::Agent
    @agent_new_orig = agent_class.method(:new)
    agent_class.singleton_class.send(:remove_method, :new) if agent_class.singleton_class.method_defined?(:new, false)
    agent_class.define_singleton_method(:new) { |**_| fake }
    fake
  end

  def teardown
    if @agent_new_orig
      agent_class = Space::Src::Launchd::Agent
      agent_class.singleton_class.send(:remove_method, :new) if agent_class.singleton_class.method_defined?(:new, false)
      agent_class.define_singleton_method(:new, &@agent_new_orig)
    end
    super
  end

  # (f) `agent install` writes a plist under HOME/Library/LaunchAgents with the
  # label/StartInterval/argv AC5 requires, and bootstraps it via the (stubbed) Agent.
  def test_agent_install_writes_plist_and_bootstraps
    setup = temp_env
    with_env(setup[:env].merge("SPACE_ARCHITECT_BIN_PATH" => "/usr/local/bin/architect")) do
      fake = stub_agent
      out, err = invoke("sessions", "agent", "install", "--host", "http://example.com",
        "--token", "secret-token", "--interval", "1800")

      assert_empty err
      assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code

      label = Space::Architect::SessionSync::LABEL
      pp = File.join(setup[:env]["HOME"], "Library", "LaunchAgents", "#{label}.plist")
      assert File.exist?(pp), "plist not written to #{pp}"

      xml = File.read(pp)
      assert_match(/<key>Label<\/key>\s*<string>#{Regexp.escape(label)}<\/string>/, xml)
      assert_match(/<key>StartInterval<\/key>\s*<integer>1800<\/integer>/, xml)
      m = xml.match(/<key>ProgramArguments<\/key>\s*<array>(.*?)<\/array>/m)
      args = m[1].scan(/<string>([^<]*)<\/string>/).flatten
      assert_equal ["/usr/local/bin/architect", "sessions", "sync", "--host", "http://example.com", "--token", "secret-token"], args

      assert_equal [[:install, pp]], fake.calls
      assert_match(/Installed/, out)
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (g) an op:// token is written into the plist as the ref, never resolved.
  def test_agent_install_writes_op_token_as_ref
    setup = temp_env
    with_env(setup[:env].merge("SPACE_ARCHITECT_BIN_PATH" => "/usr/local/bin/architect")) do
      stub_agent
      invoke("sessions", "agent", "install", "--host", "http://example.com",
        "--token", "op://vault/space-architect/session-sync-token")

      label = Space::Architect::SessionSync::LABEL
      pp = File.join(setup[:env]["HOME"], "Library", "LaunchAgents", "#{label}.plist")
      xml = File.read(pp)
      assert_match(%r{<string>op://vault/space-architect/session-sync-token</string>}, xml)
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (h) `agent uninstall` bootouts (via the stub) and removes the plist.
  def test_agent_uninstall_removes_plist
    setup = temp_env
    with_env(setup[:env].merge("SPACE_ARCHITECT_BIN_PATH" => "/usr/local/bin/architect")) do
      fake = stub_agent
      invoke("sessions", "agent", "install", "--host", "http://example.com", "--token", "tok")

      label = Space::Architect::SessionSync::LABEL
      pp = File.join(setup[:env]["HOME"], "Library", "LaunchAgents", "#{label}.plist")
      assert File.exist?(pp)

      out, _err = invoke("sessions", "agent", "uninstall")
      assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
      refute File.exist?(pp)
      assert_includes fake.calls, [:uninstall]
      assert_match(/Removed plist/, out)
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (i) `agent status` reports the (stubbed) loaded/running/last-exit state.
  def test_agent_status_reports_state
    setup = temp_env
    with_env(setup[:env]) do
      stub_agent(status_result: Dry::Monads::Success({loaded: true, running: true, pid: 4242, last_exit: 0}))
      out, err = invoke("sessions", "agent", "status")

      assert_empty err
      assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
      assert_match(/loaded: true/, out)
      assert_match(/running: true/, out)
      assert_match(/4242/, out)
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (j) `agent install` requires --host/--token.
  def test_agent_install_requires_host_and_token
    setup = temp_env
    with_env(setup[:env]) do
      _out, err = invoke("sessions", "agent", "install", "--token", "tok")
      refute_equal 0, Space::Architect::CLI.last_outcome&.exit_code
      assert_match(/host/i, err)
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end
end

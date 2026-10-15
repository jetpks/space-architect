# frozen_string_literal: true

require_relative "test_helper"
require "async/http/mock"
require "async/http/client"
require "protocol/http/response"
require "json"
require "zlib"

class SpacePushTest < Space::ArchitectTest
  # ── Packer: bundle cut against a fake space tree ────────────────────────────

  def build_fake_space(dir)
    seed_git_repo(dir) # .git/ must be IN — iteration timestamps live in history
    write(dir, "space.yaml", "version: 1\nid: test-space\n")
    write(dir, "architecture/I01-lanes.md", "# lanes\n")
    write(dir, "notes/ideas.md", "ideas\n")
    write(dir, "build/I01-lane-a/prompt.md", "prompt\n")
    write(dir, "build/I01-lane-a/report.md", "report\n")
    write(dir, "build/I01-lane-a/run.jsonl", "{\"event\":1}\n")
    write(dir, "build/I01-lane-a/wt/lib/app.rb", "hidden worktree\n")
    write(dir, "repos/big/.git/config", "hidden repo\n")
    write(dir, "tmp/cache.bin", "hidden tmp\n")
    write(dir, "vendor/node_modules/pkg/index.js", "hidden node_modules\n")
    write(dir, ".pi/config.toml", "hidden pi\n")
    write(dir, "debug.log", "hidden log\n")
  end

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # Reads the gzip'd tar's entries as {name => content} (directories nil).
  # Understands GNU 'L' long-name entries.
  def tar_entries(path)
    entries = {}
    long_name = nil
    Zlib::GzipReader.open(path) do |gz|
      until gz.eof?
        header = gz.read(Space::Architect::SpacePush::Packer::BLOCK_SIZE)
        break if header.nil? || header.bytes.all?(&:zero?)

        name    = header[0, 100].delete("\0")
        prefix  = header[345, 155].delete("\0")
        size    = header[124, 12].to_i(8)
        type    = header[156, 1]
        content = gz.read(size) if size > 0
        gz.read(padding(size)) if size > 0 # skip block padding
        name = prefix.empty? ? name : "#{prefix}/#{name}"
        if type == "L"
          long_name = content.delete("\0")
        else
          entries[long_name || name] = type == "5" ? nil : content
          long_name = nil
        end
      end
    end
    entries
  end

  def padding(size)
    (Space::Architect::SpacePush::Packer::BLOCK_SIZE - (size % Space::Architect::SpacePush::Packer::BLOCK_SIZE)) % Space::Architect::SpacePush::Packer::BLOCK_SIZE
  end

  # The importer's read set is IN; repos/worktrees/tmp/node_modules/.pi/log OUT.
  def test_pack_includes_importer_read_set_and_excludes_bulk
    Dir.mktmpdir do |dir|
      build_fake_space(dir)
      entries = tar_entries(Space::Architect::SpacePush::Packer.new(dir).pack)

      assert_includes entries, "space.yaml"
      assert_equal "version: 1\nid: test-space\n", entries["space.yaml"]
      assert_equal "# lanes\n", entries["architecture/I01-lanes.md"]
      assert_equal "ideas\n", entries["notes/ideas.md"]
      assert_equal "prompt\n", entries["build/I01-lane-a/prompt.md"]
      assert_equal "report\n", entries["build/I01-lane-a/report.md"]
      assert_equal "{\"event\":1}\n", entries["build/I01-lane-a/run.jsonl"]
      assert entries.keys.any? { |n| n.start_with?(".git/") }
      assert entries.keys.any? { |n| n.end_with?("/") } # directories are recorded

      excluded = entries.keys.grep(%r{\A(repos/|tmp/|\.pi/)|(/wt/|node_modules/)|\.log\z})
      assert_empty excluded
    end
  end

  # The bundle is valid gzip (GzipReader above proves it) and executability
  # survives the round-trip via the mode field.
  def test_pack_preserves_executable_mode
    Dir.mktmpdir do |dir|
      build_fake_space(dir)
      script = File.join(dir, "script/run.sh")
      FileUtils.mkdir_p(File.dirname(script))
      File.write(script, "#!/bin/sh\n")
      File.chmod(0o755, script)

      path = Space::Architect::SpacePush::Packer.new(dir).pack
      Zlib::GzipReader.open(path) do |gz|
        loop do
          header = gz.read(Space::Architect::SpacePush::Packer::BLOCK_SIZE)
          break if header.nil? || header.bytes.all?(&:zero?)

          size = header[124, 12].to_i(8)
          if header[0, 100].delete("\0") == "script/run.sh"
            assert_equal 0o755, header[100, 8].to_i(8)
          end
          gz.read(size + padding(size)) if size > 0
        end
      end
    end
  end

  # Paths longer than the 100-byte ustar name field survive via a GNU 'L'
  # long-name entry.
  def test_pack_handles_long_names
    Dir.mktmpdir do |dir|
      build_fake_space(dir)
      long = "architecture/#{"long-section-name-" * 9}tail.md"
      FileUtils.mkdir_p(File.dirname(File.join(dir, long)))
      File.write(File.join(dir, long), "deep content\n")

      entries = tar_entries(Space::Architect::SpacePush::Packer.new(dir).pack)
      assert_equal "deep content\n", entries[long]
    end
  end

  # ── Pusher: the frozen HTTP contract ────────────────────────────────────────

  def with_bundle
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bundle.tar.gz")
      File.binwrite(path, "tar-gz-bytes")
      yield path
    end
  end

  # POST <host>/spaces/import with Bearer auth + application/gzip, streaming
  # the bundle; 200 returns the server's summary hash.
  def test_push_posts_bundle_per_the_frozen_contract
    mock_endpoint = Async::HTTP::Mock::Endpoint.new
    summary = { "id" => 7, "slug" => "my-space", "iterations" => 3, "artifacts" => 12, "runs" => 4 }

    with_bundle do |path|
      Sync do
        server_task = Async do
          mock_endpoint.run do |request|
            assert_equal "POST",                        request.method
            assert_equal "/spaces/import",              request.path
            assert_equal "Bearer secret-token",         request.headers["authorization"]
            assert_equal "application/gzip",            request.headers["content-type"]
            assert_equal "tar-gz-bytes",                request.body&.read
            Protocol::HTTP::Response[200, [["content-type", "application/json"]], [JSON.generate(summary)]]
          end
        end

        client  = Async::HTTP::Client.new(mock_endpoint)
        pusher  = Space::Architect::SpacePush.new("http://localhost", "secret-token", client: client)
        assert_equal summary, pusher.push(path)

        client.close
        server_task.stop
      end
    end
  end

  # Non-200: the server's error body is surfaced and the push fails loudly.
  def test_push_raises_with_error_body_on_non_200
    mock_endpoint = Async::HTTP::Mock::Endpoint.new

    with_bundle do |path|
      Sync do
        server_task = Async do
          mock_endpoint.run do |_request|
            Protocol::HTTP::Response[400, [["content-type", "application/json"]],
                                     [JSON.generate({ error: "bad tar" })]]
          end
        end

        client = Async::HTTP::Client.new(mock_endpoint)
        pusher = Space::Architect::SpacePush.new("http://localhost", "secret-token", client: client)
        error  = assert_raises(Space::Core::Error) { pusher.push(path) }
        assert_match(/400.*bad tar/m, error.message)

        client.close
        server_task.stop
      end
    end
  end
end

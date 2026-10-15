# frozen_string_literal: true

require "zlib"
require "tempfile"
require "json"
require "async/http/client"
require "async/http/endpoint"
require "protocol/http/body/readable"

module Space::Architect
  # Gem-side sender for the space-server import mouth: packs the current space
  # into a gzipped tar and POSTs it to <host>/spaces/import
  # (Content-Type: application/gzip, Bearer auth). A 200 response is the
  # server's import summary {id:, slug:, iterations:, artifacts:, runs:};
  # any non-200 raises Space::Core::Error carrying the server's error body.
  class SpacePush
    IMPORT_PATH  = "/spaces/import"
    CONTENT_TYPE = "application/gzip"

    def initialize(host, token, client: nil)
      @host   = host.chomp("/")
      @token  = token
      @client = client
    end

    # POSTs a packed bundle (a gzip tar path) per the frozen import contract
    # and returns the parsed summary hash. Raises Space::Core::Error on any
    # non-200 — the CLI's handle_errors turns that into a stderr message and
    # a nonzero exit.
    def push(bundle_path)
      Sync do
        with_client do |c|
          body = file_body(bundle_path)
          begin
            response = c.post(IMPORT_PATH, headers: headers, body: body)
            parse_response(response)
          ensure
            body.close
          end
        end
      end
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError => e
      raise Space::Core::Error, "POST #{IMPORT_PATH} failed: #{e.message} (host: #{@host})"
    end

    private

    def with_client
      if @client
        yield @client
      else
        Async::HTTP::Client.open(Async::HTTP::Endpoint.parse(@host)) { |c| yield c }
      end
    end

    def headers
      [
        ["authorization", "Bearer #{@token}"],
        ["content-type",  CONTENT_TYPE]
      ]
    end

    # Streams the bundle off disk — the bundle is never slurped into memory.
    # StreamBody's length drives the content-length on the wire (HTTP/1) and
    # the HTTP/2 pseudo-header, so it must not also be set as a header.
    def file_body(bundle_path)
      StreamBody.new(File.open(bundle_path, "rb"), File.size(bundle_path))
    end

    def parse_response(response)
      status = response.status
      body   = response.read || ""
      raise Space::Core::Error, "POST #{IMPORT_PATH} failed (#{status}): #{body[0, 200]}" unless status == 200

      JSON.parse(body)
    end

    # A Protocol::HTTP body that lazily reads chunks off an IO, so the HTTP
    # client streams the request body while the bundle stays on disk.
    class StreamBody < Protocol::HTTP::Body::Readable
      CHUNK_SIZE = 64 * 1024

      def initialize(io, length)
        @io     = io
        @length = length
      end

      attr :length

      def read
        @io.read(CHUNK_SIZE)
      end

      def close(error = nil)
        @io.close unless @io.closed?
        super
      end
    end

    # Packs a space into a gzipped tar on disk, streaming — neither the tar
    # nor the space's files are held in memory.
    #
    # Bundle cut (correctness-critical): EXCLUDE repos/, the lanes' worktrees
    # at build/<id>-<lane>/wt, tmp/, node_modules/ anywhere, .pi/, and *.log
    # files. INCLUDE everything else — the importer's read set is space.yaml,
    # .git/ (history carries iteration timestamps), architecture/, notes/,
    # and build/<id>-<lane>/{prompt,report}.md + run.jsonl.
    class Packer
      BLOCK_SIZE     = 512
      PRUNED_DIRS    = %w[repos tmp .pi node_modules]
      WORKTREE_MATCH = %r{\Abuild/[^/]+/wt\z}

      Entry = Struct.new(:name, :path, :type)

      def initialize(root)
        @root = root.to_s
      end

      # Streams the space into a fresh tmpfile and returns its path. The
      # caller owns the tmpfile (unlink it when done).
      def pack
        tmp = Tempfile.create(["architect-push", ".tar.gz"])
        tmp.binmode
        Zlib::GzipWriter.wrap(tmp) do |gz|
          writer = TarWriter.new(gz)
          walk { |entry| add(writer, entry) }
          writer.finish
        end
        tmp.close
        tmp.path
      rescue
        tmp.close
        File.unlink(tmp.path) rescue nil
        raise
      end

      private

      def add(writer, entry)
        if entry.type == :dir
          writer.write_dir(entry.name, mtime: File.mtime(entry.path))
        else
          writer.write_file(entry.path, entry.name,
            mode: File.stat(entry.path).mode & 0o7777, mtime: File.mtime(entry.path))
        end
      end

      def walk(&)
        walk_dir("", &)
      end

      def walk_dir(rel, &)
        dir = rel.empty? ? @root : File.join(@root, rel)
        Dir.children(dir).sort.each do |name| # paths:exempt — the dotfile-inclusive walk is deliberate (.git must ship); pruned subtrees (repos/, worktrees) are skipped before descending, so their bulk is never enumerated and the walk streams
          child = rel.empty? ? name : "#{rel}/#{name}"
          abs   = File.join(@root, child)
          stat  = File.lstat(abs)

          if stat.directory?
            next if pruned?(child)

            yield Entry.new("#{child}/", abs, :dir)
            walk_dir(child, &)
          elsif stat.file?
            next if child.end_with?(".log")

            yield Entry.new(child, abs, :file)
          end
          # Symlinks and other oddities are skipped: the bundle carries regular
          # files and directories only, so it stays traversal-proof.
        end
      end

      def pruned?(rel)
        PRUNED_DIRS.include?(File.basename(rel)) || WORKTREE_MATCH.match?(rel)
      end

      # Minimal ustar writer — stdlib only, the Gemfile carries no tar gem.
      # Regular files and directories; file contents stream 512-byte-aligned.
      # Names longer than 100 bytes split across the ustar prefix field.
      class TarWriter
        BLOCK_SIZE = 512
        TYPE_FILE  = "0"
        TYPE_DIR   = "5"

        def initialize(io)
          @io = io
        end

        def write_dir(name, mtime:)
          write_header(name, mode: 0o755, mtime: mtime, size: 0, type: TYPE_DIR)
        end

        def write_file(path, name, mode:, mtime:)
          size = File.size(path)
          write_header(name, mode: mode, mtime: mtime, size: size, type: TYPE_FILE)
          IO.copy_stream(path, @io)
          pad = (BLOCK_SIZE - (size % BLOCK_SIZE)) % BLOCK_SIZE
          @io.write("\0" * pad) unless pad.zero?
        end

        # Two zero blocks terminate the archive.
        def finish
          @io.write("\0" * (BLOCK_SIZE * 2))
        end

        private

        def write_header(name, mode:, mtime:, size:, type:)
          name = name.b
          split = split_name(name)
          if split
            base, prefix = split
          else
            # Not representable via the ustar prefix field — fall back to a
            # GNU 'L' long-name entry, which every mainstream reader honors.
            write_long_name(name)
            base, prefix = name[0, 100], nil
          end

          header = String.new(encoding: Encoding::BINARY)
          header << base.ljust(100, "\0")
          header << octal(mode, 8)
          header << octal(0, 8)          # uid — the bundle is anonymous
          header << octal(0, 8)          # gid
          header << octal(size, 12)
          header << octal(mtime.to_i, 12)
          header << " " * 8              # checksum placeholder
          header << type
          header << "\0" * 100           # linkname
          header << "ustar\0"            # magic
          header << "00"                 # version
          header << "\0" * 32            # uname
          header << "\0" * 32            # gname
          header << "\0" * 8             # devmajor
          header << "\0" * 8             # devminor
          header << (prefix || "").ljust(155, "\0")
          header << "\0" * (BLOCK_SIZE - header.bytesize)
          raise "tar header overflow: #{name}" if header.bytesize != BLOCK_SIZE

          header[148, 8] = format("%06o\0 ", header.sum)
          @io.write(header)
        end

        # GNU 'L' long-name entry: the full name NUL-terminated as the entry
        # body, then the real header carrying the name's first 100 bytes.
        def write_long_name(name)
          content = "#{name}\0"
          write_header("././@LongLink", mode: 0o644, mtime: Time.now, size: content.bytesize, type: "L")
          @io.write(content)
          pad = (BLOCK_SIZE - (content.bytesize % BLOCK_SIZE)) % BLOCK_SIZE
          @io.write("\0" * pad) unless pad.zero?
        end

        # [base, prefix] split across the ustar name (100) and prefix (155)
        # fields at a "/" boundary, or nil when the name cannot be split and
        # needs a GNU long-name entry.
        def split_name(name)
          return [name, nil] if name.bytesize <= 100

          min_cut = [name.bytesize - 101, 0].max # the name field must fit in 100 bytes
          cut = name.index("/", min_cut)
          return nil if cut.nil? || cut > 155

          [name[(cut + 1)..], name[0, cut]]
        end

        def octal(value, width)
          format("%0#{width - 1}o\0", value)
        end
      end
    end
  end
end

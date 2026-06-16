# frozen_string_literal: true

require "async/process"
require "pathname"
require "tempfile"

module SpaceCadet
  class MiseClient
    def trust(path)
      path = Pathname.new(path)
      stdout, stderr, status = capture("mise", "trust", "--yes", "--quiet", "--cd", path.to_s)
      return true if status.success?

      output = [stdout, stderr].reject(&:empty?).join("\n").strip
      message = "mise trust failed for #{path}"
      message = "#{message}: #{output}" unless output.empty?
      raise MiseError, message
    rescue Errno::ENOENT
      raise MiseError, "mise executable not found; install mise or make sure it is on PATH"
    end

    private

    def capture(*command)
      stdout = Tempfile.new("project-spaces-mise-stdout")
      stderr = Tempfile.new("project-spaces-mise-stderr")
      status = Warnings.without_experimental do
        Async::Process.spawn(*command, out: stdout, err: stderr)
      end

      stdout.rewind
      stderr.rewind
      [stdout.read, stderr.read, status]
    ensure
      stdout&.close!
      stderr&.close!
    end
  end
end

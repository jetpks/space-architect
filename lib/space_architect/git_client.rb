# frozen_string_literal: true

require "fileutils"
require "async/process"
require "pathname"
require "tempfile"

module SpaceArchitect
  class GitClient
    def init(path)
      path = Pathname.new(path)
      stdout, stderr, status = capture("git", "-C", path.to_s, "init")
      return true if status.success?

      output = [stdout, stderr].reject(&:empty?).join("\n").strip
      message = "git init failed for #{path}"
      message = "#{message}: #{output}" unless output.empty?
      raise GitError, message
    end

    # Best-effort: a missing git identity (user.name/user.email) must not abort
    # space creation. Returns false on failure, leaving the repo initialized but
    # uncommitted.
    def commit_all(path, message)
      path = Pathname.new(path)
      _, _, add_status = capture("git", "-C", path.to_s, "add", "-A")
      return false unless add_status.success?

      _, _, commit_status = capture("git", "-C", path.to_s, "commit", "-m", message)
      commit_status.success?
    end

    private

    def capture(*command)
      stdout = Tempfile.new("project-spaces-git-stdout")
      stderr = Tempfile.new("project-spaces-git-stderr")
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

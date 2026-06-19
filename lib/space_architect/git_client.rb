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

    def clone(url, path)
      path = Pathname.new(path)
      raise RepoExistsError, "Repo destination already exists: #{path}" if path.exist?

      FileUtils.mkdir_p(path.dirname)
      stdout, stderr, status = capture("git", "clone", url, path.to_s)
      return true if status.success?

      output = [stdout, stderr].reject(&:empty?).join("\n").strip
      message = "git clone failed for #{url}"
      message = "#{message}: #{output}" unless output.empty?
      raise GitError, message
    end

    def copy(source, path)
      source = Pathname.new(source)
      path = Pathname.new(path)
      raise RepoExistsError, "Repo destination already exists: #{path}" if path.exist?
      raise GitError, "Evergreen source missing: #{source}" unless source.directory?

      FileUtils.mkdir_p(path.dirname)
      stdout, stderr, status = capture(*copy_command(source, path))
      return true if status.success?

      output = [stdout, stderr].reject(&:empty?).join("\n").strip
      message = "copy failed for #{source}"
      message = "#{message}: #{output}" unless output.empty?
      raise GitError, message
    end

    private

    # On APFS (macOS) prefer a copy-on-write clone: near-instant and
    # space-efficient. Elsewhere fall back to a plain recursive copy.
    def copy_command(source, path)
      flags = RbConfig::CONFIG["host_os"].match?(/darwin/) ? "-Rc" : "-R"
      ["cp", flags, source.to_s, path.to_s]
    end

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

# frozen_string_literal: true

require "yaml"
require "erb"
require "open3"
require "fileutils"
require "pathname"

module SpaceCadet
  class ArchitectMission
    def initialize(space:)
      @space = space
    end

    def init!
      handoff_path = space.path.join("artifacts", "HANDOFF.md")
      if handoff_path.exist?
        raise Error, "artifacts/HANDOFF.md already exists — remove it first or edit it directly (idempotent guard)"
      end

      %w[gates lanes prd].each do |dir|
        target = space.path.join("artifacts", dir)
        FileUtils.mkdir_p(target)
        FileUtils.touch(target.join(".gitkeep"))
      end

      FileUtils.mkdir_p(handoff_path.dirname)
      handoff_path.write(render_handoff)

      update_architect_block do |b|
        b.merge("status" => "active", "current_slice" => nil, "slices" => [])
      end

      git_run("-C", space.path.to_s, "add",
        "artifacts/HANDOFF.md",
        "artifacts/gates/.gitkeep",
        "artifacts/lanes/.gitkeep",
        "artifacts/prd/.gitkeep",
        ".space.yml")
      git_run("-C", space.path.to_s, "commit", "-m", "Initialize architect mission")

      handoff_path
    end

    def status
      block = space.data["architect"] || {}
      gates_dir = space.path.join("artifacts", "gates")
      lanes_dir = space.path.join("artifacts", "lanes")

      gates = if gates_dir.exist?
        gates_dir.children.reject { |f| f.basename.to_s == ".gitkeep" }.map { |f| f.basename.to_s }.sort
      else
        []
      end

      lane_reports = if lanes_dir.exist?
        lanes_dir.children.reject { |f| f.basename.to_s == ".gitkeep" }.map { |f| f.basename.to_s }.sort
      else
        []
      end

      { block: block, gates: gates, lane_reports: lane_reports }
    end

    def freeze!(slice)
      gate_file = space.path.join("artifacts", "gates", "#{slice}.md")
      unless gate_file.exist?
        raise Error, "artifacts/gates/#{slice}.md does not exist — create the gate file before freezing"
      end

      block = space.data["architect"] || {}
      slices_list = block["slices"] || []
      existing = slices_list.find { |s| s["name"] == slice }

      if existing && existing["freeze_sha"]
        freeze_sha = existing["freeze_sha"]
        diff_out, = git_capture("-C", space.path.to_s, "diff", freeze_sha, "--",
          "artifacts/gates/#{slice}.md")
        unless diff_out.strip.empty?
          raise Error,
            "Gate file changed since freeze #{freeze_sha[0, 8]} — " \
            "refusing to re-freeze. Restore artifacts/gates/#{slice}.md to its frozen state " \
            "or use a new slice name."
        end
        return freeze_sha
      end

      files_to_add = ["artifacts/gates/#{slice}.md"]
      files_to_add << "artifacts/HANDOFF.md" if space.path.join("artifacts", "HANDOFF.md").exist?
      git_run("-C", space.path.to_s, "add", *files_to_add)
      git_run("-C", space.path.to_s, "commit", "-m", "Freeze gates: #{slice}")

      sha, = git_capture("-C", space.path.to_s, "rev-parse", "HEAD")
      sha = sha.strip

      update_architect_block do |b|
        b["current_slice"] = slice
        list = b["slices"] || []
        idx = list.index { |s| s["name"] == slice }
        entry = { "name" => slice, "freeze_sha" => sha, "verdict" => "pending", "lanes" => [] }
        if idx
          list[idx] = entry
        else
          list << entry
        end
        b["slices"] = list
        b
      end

      sha
    end

    def worktree_add(repo, slice, lane, base: nil)
      repo_path = space.path.join("repos", repo)
      raise Error, "repos/#{repo} does not exist" unless repo_path.exist?

      wt_path = space.path.join("tmp", "architect", "wt", "#{slice}-#{lane}")
      FileUtils.mkdir_p(wt_path.dirname)

      base_ref = base || "HEAD"
      base_sha, _, wt_status = git_capture("-C", repo_path.to_s, "rev-parse", base_ref)
      raise Error, "Could not resolve base ref '#{base_ref}' in #{repo}" unless wt_status.success?
      base_sha = base_sha.strip

      branch = "lane/#{slice}-#{lane}"
      git_run("-C", repo_path.to_s, "worktree", "add", wt_path.to_s, "-b", branch, base_sha)

      update_architect_block do |b|
        list = b["slices"] || []
        idx = list.index { |s| s["name"] == slice }
        entry = idx ? list[idx] : { "name" => slice, "freeze_sha" => nil, "verdict" => "pending", "lanes" => [] }
        lanes = entry["lanes"] || []
        lanes << {
          "name" => lane,
          "repo" => repo,
          "base_sha" => base_sha,
          "worktree" => "tmp/architect/wt/#{slice}-#{lane}",
          "integration_branch" => nil
        }
        entry["lanes"] = lanes
        if idx
          list[idx] = entry
        else
          list << entry
        end
        b["slices"] = list
        b
      end

      { worktree: wt_path, base_sha: base_sha }
    end

    def worktree_remove(slice, lane)
      block = space.data["architect"] || {}
      slices_list = block["slices"] || []
      slice_entry = slices_list.find { |s| s["name"] == slice }
      lane_entry = slice_entry&.dig("lanes")&.find { |l| l["name"] == lane }
      raise Error, "No lane '#{lane}' recorded for slice '#{slice}'" unless lane_entry

      repo = lane_entry["repo"]
      repo_path = space.path.join("repos", repo)
      wt_path = space.path.join("tmp", "architect", "wt", "#{slice}-#{lane}")

      git_run("-C", repo_path.to_s, "worktree", "remove", "--force", wt_path.to_s)
      git_run("-C", repo_path.to_s, "worktree", "prune")

      update_architect_block do |b|
        b["slices"]&.each do |s|
          next unless s["name"] == slice
          s["lanes"] = (s["lanes"] || []).reject { |l| l["name"] == lane }
        end
        b
      end
    end

    def worktree_list
      wt_base = space.path.join("tmp", "architect", "wt")
      return [] unless wt_base.exist?
      wt_base.children.select(&:directory?).map { |p| p.basename.to_s }.sort
    end

    def verify(slice)
      block = space.data["architect"] || {}
      slices_list = block["slices"] || []
      slice_entry = slices_list.find { |s| s["name"] == slice }
      raise Error, "Slice '#{slice}' not recorded in .space.yml" unless slice_entry

      freeze_sha = slice_entry["freeze_sha"]
      lanes = slice_entry["lanes"] || []

      lanes.map do |lane|
        lane_name = lane["name"]
        base_sha = lane["base_sha"]
        wt_path = space.path.join(lane["worktree"] || "tmp/architect/wt/#{slice}-#{lane_name}")
        touch_set = lane["touch_set"] || []

        checks = {}

        # (a) gates untouched since freeze
        checks[:gates_untouched] = if freeze_sha
          diff, = git_capture("-C", space.path.to_s, "diff", freeze_sha, "--",
            "artifacts/gates/#{slice}.md")
          diff.strip.empty?
        end

        # (b) no builder commits in the worktree
        log_out, = git_capture("-C", wt_path.to_s, "log", "#{base_sha}..")
        checks[:no_builder_commits] = log_out.strip.empty?

        # (c) lane report exists and non-empty
        report = space.path.join("artifacts", "lanes", "#{slice}-#{lane_name}.md")
        checks[:lane_report_exists] = report.exist? && !report.read.strip.empty?

        # (d) in-bounds: changed paths ⊆ touch_set (best-effort, nil if no touch_set)
        checks[:in_bounds] = if touch_set.empty?
          nil
        else
          status_out, = git_capture("-C", wt_path.to_s, "status", "--porcelain")
          changed = status_out.lines.map { |l| l[3..].strip }
          changed.all? { |f| touch_set.any? { |g| File.fnmatch(g, f) } }
        end

        { lane: lane_name, repo: lane["repo"], checks: checks }
      end
    end

    private

    attr_reader :space

    def render_handoff
      @_title = space.data["title"] || space.id
      @_repos = space.repos
      template_path = Pathname.new(__dir__).join("templates", "handoff.md.erb")
      ERB.new(template_path.read, trim_mode: "-").result(binding)
    end

    def update_architect_block
      block = space.data["architect"] || { "status" => "active", "current_slice" => nil, "slices" => [] }
      space.data["architect"] = yield(block)
      space.save
    end

    def git_run(*args)
      out, err, status = Open3.capture3("git", *args)
      return if status.success?
      output = [out, err].map(&:strip).reject(&:empty?).join(" ")
      raise Error, "git #{args.join(' ')} failed: #{output}"
    end

    def git_capture(*args)
      Open3.capture3("git", *args)
    end
  end
end

# frozen_string_literal: true

require "yaml"
require "erb"
require "open3"
require "fileutils"
require "pathname"

module SpaceCadet
  # Manages an architect-loop mission inside a space: one self-contained file per
  # slice at artifacts/<NN>-<slice>.md (Grounds / Contract / Rubric / Builder
  # Prompt / Builder Report / Verdict), grown one commit per section. The freeze
  # is the commit that establishes the Rubric; the frozen region (everything
  # above "## Builder Prompt") is read-only afterward.
  class ArchitectMission
    # The heading that separates the frozen sections (Grounds/Contract/Rubric)
    # from the appended-after-freeze sections (Builder Prompt/Report/Verdict).
    FROZEN_BOUNDARY = /^## Builder Prompt/

    def initialize(space:)
      @space = space
    end

    def init!
      handoff_path = space.path.join("artifacts", "HANDOFF.md")
      if handoff_path.exist?
        raise Error, "artifacts/HANDOFF.md already exists — remove it first or edit it directly (idempotent guard)"
      end

      FileUtils.mkdir_p(handoff_path.dirname)
      handoff_path.write(render_handoff)

      update_architect_block do |b|
        b.merge("status" => "active", "current_slice" => nil, "slices" => [])
      end

      git_run("-C", space.path.to_s, "add", "artifacts/HANDOFF.md", ".space.yml")
      git_run("-C", space.path.to_s, "commit", "-m", "Initialize architect mission")

      handoff_path
    end

    # Allocate the next ordinal and scaffold artifacts/<NN>-<slice>.md.
    def new_slice!(slice)
      block = space.data["architect"] || {}
      slices = block["slices"] || []
      if slices.any? { |s| s["name"] == slice }
        raise Error, "slice '#{slice}' already exists in .space.yml"
      end

      ordinal = (slices.map { |s| s["ordinal"] || 0 }.max || 0) + 1
      nn = format("%02d", ordinal)
      rel = "artifacts/#{nn}-#{slice}.md"
      path = space.path.join(rel)
      raise Error, "#{rel} already exists" if path.exist?

      FileUtils.mkdir_p(path.dirname)
      path.write(render_slice(nn, slice))

      update_architect_block do |b|
        b["current_slice"] = slice
        list = b["slices"] || []
        list << {
          "name" => slice, "ordinal" => ordinal, "file" => rel,
          "freeze_sha" => nil, "verdict" => "pending", "lanes" => []
        }
        b["slices"] = list
        b
      end

      git_run("-C", space.path.to_s, "add", rel, ".space.yml")
      git_run("-C", space.path.to_s, "commit", "-m", "slice #{nn}: scaffold #{slice}")

      path
    end

    def status
      block = space.data["architect"] || {}
      artifacts_dir = space.path.join("artifacts")
      slice_files = if artifacts_dir.exist?
        artifacts_dir.children
          .select { |f| f.basename.to_s.match?(/\A\d+-.+\.md\z/) }
          .map { |f| f.basename.to_s }.sort
      else
        []
      end
      { block: block, slice_files: slice_files }
    end

    # Freeze the slice: the slice file must carry a "## Rubric" section. Commits
    # any pending changes to the slice file and records HEAD as freeze_sha. If
    # already frozen, refuses when the frozen region has changed since.
    def freeze!(slice)
      entry = slice_entry(slice)
      rel = entry["file"]
      path = space.path.join(rel)
      raise Error, "#{rel} does not exist — run `space architect new #{slice}` first" unless path.exist?
      unless path.read.match?(/^## Rubric/)
        raise Error, "#{rel} has no '## Rubric' section — write the Rubric before freezing"
      end

      if entry["freeze_sha"]
        sha = entry["freeze_sha"]
        if frozen_region_changed?(sha, rel)
          raise Error,
            "Frozen sections of #{rel} changed since freeze #{sha[0, 8]} — " \
            "refusing to re-freeze. Restore them to their frozen state or use a new slice."
        end
        return sha
      end

      files = [rel]
      files << "artifacts/HANDOFF.md" if space.path.join("artifacts", "HANDOFF.md").exist?
      git_run("-C", space.path.to_s, "add", *files)
      if staged_changes?
        nn = format("%02d", entry["ordinal"] || 0)
        git_run("-C", space.path.to_s, "commit", "-m", "slice #{nn}: rubric (freeze)")
      end

      sha, = git_capture("-C", space.path.to_s, "rev-parse", "HEAD")
      sha = sha.strip

      update_architect_block do |b|
        b["current_slice"] = slice
        (b["slices"] || []).each do |s|
          next unless s["name"] == slice
          s["freeze_sha"] = sha
          s["verdict"] ||= "pending"
        end
        b
      end

      sha
    end

    def worktree_add(repo, slice, lane, base: nil)
      slice_entry(slice) # require the slice to be recorded first
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
        (b["slices"] || []).each do |s|
          next unless s["name"] == slice
          lanes = s["lanes"] || []
          lanes << {
            "name" => lane,
            "repo" => repo,
            "base_sha" => base_sha,
            "worktree" => "tmp/architect/wt/#{slice}-#{lane}",
            "integration_branch" => nil
          }
          s["lanes"] = lanes
        end
        b
      end

      { worktree: wt_path, base_sha: base_sha }
    end

    def worktree_remove(slice, lane)
      entry = slice_entry(slice)
      lane_entry = (entry["lanes"] || []).find { |l| l["name"] == lane }
      raise Error, "No lane '#{lane}' recorded for slice '#{slice}'" unless lane_entry

      repo = lane_entry["repo"]
      repo_path = space.path.join("repos", repo)
      wt_path = space.path.join("tmp", "architect", "wt", "#{slice}-#{lane}")

      git_run("-C", repo_path.to_s, "worktree", "remove", "--force", wt_path.to_s)
      git_run("-C", repo_path.to_s, "worktree", "prune")

      update_architect_block do |b|
        (b["slices"] || []).each do |s|
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
      entry = slice_entry(slice)
      freeze_sha = entry["freeze_sha"]
      rel = entry["file"]
      lanes = entry["lanes"] || []

      lanes.map do |lane|
        lane_name = lane["name"]
        base_sha = lane["base_sha"]
        wt_path = space.path.join(lane["worktree"] || "tmp/architect/wt/#{slice}-#{lane_name}")
        touch_set = lane["touch_set"] || []

        checks = {}

        # (a) frozen sections of the slice file untouched since freeze
        checks[:frozen_untouched] = if freeze_sha && rel
          !frozen_region_changed?(freeze_sha, rel)
        end

        # (b) no builder commits in the worktree
        log_out, = git_capture("-C", wt_path.to_s, "log", "#{base_sha}..")
        checks[:no_builder_commits] = log_out.strip.empty?

        # (c) builder's scratch report exists and is non-empty
        report = space.path.join("tmp", "architect", "#{slice}-#{lane_name}.report.md")
        checks[:report_exists] = report.exist? && !report.read.strip.empty?

        # (d) in-bounds: changed paths ⊆ touch_set (nil if no touch_set recorded)
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

    def slice_entry(slice)
      block = space.data["architect"] || {}
      entry = (block["slices"] || []).find { |s| s["name"] == slice }
      raise Error, "Slice '#{slice}' not recorded in .space.yml — run `space architect new #{slice}` first" unless entry
      entry
    end

    # Everything above the "## Builder Prompt" heading is frozen at freeze time.
    def frozen_region(text)
      idx = text =~ FROZEN_BOUNDARY
      idx ? text[0...idx] : text
    end

    def frozen_region_changed?(freeze_sha, rel)
      old, _, st = git_capture("-C", space.path.to_s, "show", "#{freeze_sha}:#{rel}")
      return true unless st.success?
      current = space.path.join(rel).read
      frozen_region(old) != frozen_region(current)
    end

    def staged_changes?
      _o, _e, st = git_capture("-C", space.path.to_s, "diff", "--cached", "--quiet")
      !st.success? # --quiet exits non-zero when there are staged differences
    end

    def render_handoff
      @_title = space.data["title"] || space.id
      @_repos = space.repos
      render_template("handoff.md.erb")
    end

    def render_slice(ordinal_nn, name)
      @_ordinal = ordinal_nn
      @_name = name
      render_template("slice.md.erb")
    end

    def render_template(filename)
      template_path = Pathname.new(__dir__).join("templates", filename)
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

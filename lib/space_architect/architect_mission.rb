# frozen_string_literal: true

require "yaml"
require "erb"
require "open3"
require "fileutils"
require "pathname"

module SpaceArchitect
  # Manages an architect-loop mission inside a space: one self-contained file per
  # iteration at architecture/I<NN>-<iteration>.md (Grounds / Specification / Acceptance Criteria / Builder
  # Prompt / Builder Report / Verdict), grown one commit per section. The freeze
  # is the commit that establishes the Acceptance Criteria; the frozen region (everything
  # above "## Builder Prompt") is read-only afterward.
  class ArchitectMission
    # The heading that separates the frozen sections (Grounds/Specification/Acceptance Criteria)
    # from the appended-after-freeze sections (Builder Prompt/Report/Verdict).
    FROZEN_BOUNDARY = /^## Builder Prompt/

    def initialize(space:)
      @space = space
    end

    def init!
      handoff_path = space.path.join("architecture", "ARCHITECT.md")
      if handoff_path.exist?
        raise Error, "architecture/ARCHITECT.md already exists — remove it first or edit it directly (idempotent guard)"
      end

      FileUtils.mkdir_p(handoff_path.dirname)
      handoff_path.write(render_handoff)

      update_architect_block do |b|
        b.merge("status" => "active", "current_iteration" => nil, "iterations" => [])
      end

      git_run("-C", space.path.to_s, "add", "architecture/ARCHITECT.md", Space::METADATA_FILE)
      git_run("-C", space.path.to_s, "commit", "-m", "Initialize architect mission")

      handoff_path
    end

    # Allocate the next ordinal and scaffold architecture/I<NN>-<iteration>.md.
    def new_iteration!(name)
      block = space.data["architect"] || {}
      iterations = block["iterations"] || []
      if iterations.any? { |s| s["name"] == name }
        raise Error, "iteration '#{name}' already exists in space.yaml"
      end

      ordinal = (iterations.map { |s| s["ordinal"] || 0 }.max || 0) + 1
      nn = format("%02d", ordinal)
      rel = "architecture/I#{nn}-#{name}.md"
      path = space.path.join(rel)
      raise Error, "#{rel} already exists" if path.exist?

      FileUtils.mkdir_p(path.dirname)
      path.write(render_iteration(nn, name))

      update_architect_block do |b|
        b["current_iteration"] = name
        list = b["iterations"] || []
        list << {
          "name" => name, "ordinal" => ordinal, "file" => rel,
          "freeze_sha" => nil, "verdict" => "pending", "lanes" => []
        }
        b["iterations"] = list
        b
      end

      git_run("-C", space.path.to_s, "add", rel, Space::METADATA_FILE)
      git_run("-C", space.path.to_s, "commit", "-m", "I#{nn}: scaffold #{name}")

      path
    end

    def status
      block = space.data["architect"] || {}
      architecture_dir = space.path.join("architecture")
      iteration_files = if architecture_dir.exist?
        architecture_dir.children
          .select { |f| f.basename.to_s.match?(/\AI\d+-.+\.md\z/) }
          .map { |f| f.basename.to_s }.sort
      else
        []
      end
      { block: block, iteration_files: iteration_files }
    end

    # Freeze the iteration: the iteration file must carry a "## Acceptance Criteria" section. Commits
    # any pending changes to the iteration file and records HEAD as freeze_sha. If
    # already frozen, refuses when the frozen region has changed since.
    def freeze!(iteration)
      entry = slice_entry(iteration)
      rel = entry["file"]
      path = space.path.join(rel)
      raise Error, "#{rel} does not exist — run `architect new #{iteration}` first" unless path.exist?
      unless path.read.match?(/^## Acceptance Criteria/)
        raise Error, "#{rel} has no '## Acceptance Criteria' section — write the Acceptance Criteria before freezing"
      end

      if entry["freeze_sha"]
        sha = entry["freeze_sha"]
        if frozen_region_changed?(sha, rel)
          raise Error,
            "Frozen sections of #{rel} changed since freeze #{sha[0, 8]} — " \
            "refusing to re-freeze. Restore them to their frozen state or use a new iteration."
        end
        return sha
      end

      files = [rel]
      files << "architecture/ARCHITECT.md" if space.path.join("architecture", "ARCHITECT.md").exist?
      git_run("-C", space.path.to_s, "add", *files)
      if staged_changes?
        nn = format("%02d", entry["ordinal"] || 0)
        git_run("-C", space.path.to_s, "commit", "-m", "I#{nn}: acceptance criteria (freeze)")
      end

      sha, = git_capture("-C", space.path.to_s, "rev-parse", "HEAD")
      sha = sha.strip

      update_architect_block do |b|
        b["current_iteration"] = iteration
        (b["iterations"] || []).each do |s|
          next unless s["name"] == iteration
          s["freeze_sha"] = sha
          s["verdict"] ||= "pending"
        end
        b
      end

      sha
    end

    def worktree_add(repo, iteration, lane, base: nil, harness: "claude-code", model: nil, variant: false)
      if harness.to_s == "opencode" && (model.nil? || model == Harness::CLAUDE_DEFAULT_MODEL)
        raise Error,
          "Pass --model when using --harness opencode " \
          "(#{Harness::CLAUDE_DEFAULT_MODEL} is a Claude model ID, not valid for opencode — " \
          "try e.g. fireworks-ai/accounts/fireworks/models/glm-5p2)"
      end

      entry = slice_entry(iteration)
      repo_path = space.path.join("repos", repo)
      raise Error, "repos/#{repo} does not exist" unless repo_path.exist?

      id = iteration_id(entry)
      wt_path = space.path.join("build", "#{id}-#{lane}", "wt")
      FileUtils.mkdir_p(wt_path.dirname)

      base_ref = base || "HEAD"
      base_sha, _, wt_status = git_capture("-C", repo_path.to_s, "rev-parse", base_ref)
      raise Error, "Could not resolve base ref '#{base_ref}' in #{repo}" unless wt_status.success?
      base_sha = base_sha.strip

      branch = "lane/#{id}-#{lane}"
      git_run("-C", repo_path.to_s, "worktree", "add", wt_path.to_s, "-b", branch, base_sha)

      update_architect_block do |b|
        (b["iterations"] || []).each do |s|
          next unless s["name"] == iteration
          lanes = s["lanes"] || []
          lanes << {
            "name" => lane,
            "repo" => repo,
            "base_sha" => base_sha,
            "worktree" => "build/#{id}-#{lane}/wt",
            "integration_branch" => nil,
            "harness" => harness.to_s,
            "model" => model,
            "variant" => variant
          }
          s["lanes"] = lanes
        end
        b
      end

      { worktree: wt_path, base_sha: base_sha }
    end

    # Declare a variant set for an iteration: one competing lane per (harness, model) pair,
    # all sharing a byte-identical prompt. Returns descriptors for each created variant.
    def variant_add(repo, iteration, pairs, base: nil, prompt: nil)
      prompt_bytes = prompt ? File.binread(prompt) : nil
      entry = slice_entry(iteration)
      id = iteration_id(entry)
      existing_count = (entry["lanes"] || []).count { |l| l["name"].match?(/\Av\d+\z/) }

      pairs.each_with_index.map do |(harness, model), i|
        v_name = "v#{format('%02d', existing_count + i + 1)}"
        result = worktree_add(repo, iteration, v_name, base: base,
                              harness: harness, model: model, variant: true)

        if prompt_bytes
          build_dir = space.path.join("build", "#{id}-#{v_name}")
          File.open(build_dir.join("prompt.md"), "wb") { |f| f.write(prompt_bytes) }
        end

        { name: v_name, repo: repo, harness: harness, model: model,
          worktree: result[:worktree], base_sha: result[:base_sha] }
      end
    end

    # Promote one variant of an iteration's variant set as the winner: records
    # the decision durably onto the iteration entry (additive — no existing keys
    # are removed or renamed). Re-promotable: a second call reassigns "winner"
    # and recomputes every variant lane's "discarded" flag.
    def variant_promote(iteration, winner)
      entry = slice_entry(iteration)
      variant_lanes = (entry["lanes"] || []).select { |l| l["variant"] == true }
      raise Error, "Iteration '#{iteration}' has no variant set — nothing to promote" if variant_lanes.empty?
      unless variant_lanes.any? { |l| l["name"] == winner }
        raise Error, "Cannot promote '#{winner}' — not a variant lane of iteration '#{iteration}'"
      end

      discarded_names = variant_lanes.select { |l| l["name"] != winner }.map { |l| l["name"] }

      update_architect_block do |b|
        (b["iterations"] || []).each do |s|
          next unless s["name"] == iteration
          s["winner"] = winner
          (s["lanes"] || []).each do |l|
            next unless l["variant"] == true
            l["discarded"] = (l["name"] != winner)
          end
        end
        b
      end

      { winner: winner, discarded: discarded_names }
    end

    def worktree_remove(iteration, lane)
      entry = slice_entry(iteration)
      lane_entry = (entry["lanes"] || []).find { |l| l["name"] == lane }
      raise Error, "No lane '#{lane}' recorded for iteration '#{iteration}'" unless lane_entry

      repo = lane_entry["repo"]
      repo_path = space.path.join("repos", repo)
      wt_path = if lane_entry["worktree"]
        space.path.join(lane_entry["worktree"])
      else
        space.path.join("build", "#{iteration_id(entry)}-#{lane}", "wt")
      end

      git_run("-C", repo_path.to_s, "worktree", "remove", "--force", wt_path.to_s)
      git_run("-C", repo_path.to_s, "worktree", "prune")

      update_architect_block do |b|
        (b["iterations"] || []).each do |s|
          next unless s["name"] == iteration
          s["lanes"] = (s["lanes"] || []).reject { |l| l["name"] == lane }
        end
        b
      end
    end

    def worktree_list
      wt_base = space.path.join("build")
      return [] unless wt_base.exist?
      wt_base.children.select(&:directory?).map { |p| p.basename.to_s }.sort
    end

    def verify(iteration)
      entry = slice_entry(iteration)
      freeze_sha = entry["freeze_sha"]
      rel = entry["file"]
      lanes = entry["lanes"] || []

      lanes.map do |lane|
        lane_name = lane["name"]
        base_sha = lane["base_sha"]
        wt_path = space.path.join(lane["worktree"] || "build/#{iteration_id(entry)}-#{lane_name}/wt")
        touch_set = lane["touch_set"] || []

        checks = {}

        # (a) frozen sections of the iteration file untouched since freeze
        checks[:frozen_untouched] = if freeze_sha && rel
          !frozen_region_changed?(freeze_sha, rel)
        end

        # (b) no builder commits in the worktree
        log_out, = git_capture("-C", wt_path.to_s, "log", "#{base_sha}..")
        checks[:no_builder_commits] = log_out.strip.empty?

        # (c) builder's scratch report exists and is non-empty
        report = space.path.join("build", "#{iteration_id(entry)}-#{lane_name}", "report.md")
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

    def dispatch(iteration, lane, model: nil, max_turns: 200,
                 claude_bin: nil, harness: nil, opencode_bin: nil)
      entry = slice_entry(iteration)
      lane_entry = (entry["lanes"] || []).find { |l| l["name"] == lane }
      raise Error, "No lane '#{lane}' recorded for iteration '#{iteration}'" unless lane_entry

      resolved_harness = harness || lane_entry["harness"] || "claude-code"
      resolved_model   = model   || lane_entry["model"]   || Harness::CLAUDE_DEFAULT_MODEL

      id = iteration_id(entry)
      wt_path = space.path.join(lane_entry["worktree"] || "build/#{id}-#{lane}/wt")
      raise Error, "Worktree directory does not exist: #{wt_path}" unless wt_path.exist?

      build_dir    = space.path.join("build", "#{id}-#{lane}")
      prompt_path  = build_dir.join("prompt.md")
      run_log_path = build_dir.join("run.jsonl")
      report_path  = build_dir.join("report.md")
      raise Error, "prompt.md not found: #{prompt_path}" unless prompt_path.exist?

      bin = resolved_harness == "claude-code" ? claude_bin : opencode_bin
      harness_obj = Harness.for(resolved_harness, model: resolved_model, max_turns: max_turns,
                                                  bin: bin, config_dir: build_dir)

      exit_code = harness_obj.run(
        prompt_path:  prompt_path,
        run_log_path: run_log_path,
        chdir:        wt_path
      )

      { exit_code: exit_code, run_log: run_log_path, report: report_path, worktree: wt_path }
    end

    private

    attr_reader :space

    def iteration_id(entry)
      "I#{format('%02d', entry['ordinal'])}-#{entry['name']}"
    end

    def slice_entry(iteration)
      block = space.data["architect"] || {}
      entry = (block["iterations"] || []).find { |s| s["name"] == iteration }
      raise Error, "Iteration '#{iteration}' not recorded in space.yaml — run `architect new #{iteration}` first" unless entry
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
      render_template("architect.md.erb")
    end

    def render_iteration(ordinal_nn, name)
      @_ordinal = "I#{ordinal_nn}"
      @_name = name
      render_template("iteration.md.erb")
    end

    def render_template(filename)
      template_path = Pathname.new(__dir__).join("templates", filename)
      ERB.new(template_path.read, trim_mode: "-").result(binding)
    end

    def update_architect_block
      block = space.data["architect"] || { "status" => "active", "current_iteration" => nil, "iterations" => [] }
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

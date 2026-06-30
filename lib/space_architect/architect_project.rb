# frozen_string_literal: true

require "yaml"
require "erb"
require "open3"
require "fileutils"
require "pathname"
require "tempfile"

module Space::Architect
  # Manages an architect-loop project inside a space: one self-contained file per
  # iteration at architecture/I<NN>-<iteration>.md (Grounds / Specification / Acceptance Criteria / Builder
  # Prompt / Builder Report / Verdict), grown one commit per section. The freeze
  # is the commit that establishes the Acceptance Criteria; the frozen region (everything
  # above "## Builder Prompt") is read-only afterward.
  class ArchitectProject
    # The heading that separates the frozen sections (Grounds/Specification/Acceptance Criteria)
    # from the appended-after-freeze sections (Builder Prompt/Report/Verdict).
    FROZEN_BOUNDARY = /^## Builder Prompt/

    # Sections the architect writes (and the CLI commits) via `architect section`.
    # Acceptance Criteria is intentionally absent — it is set by `architect freeze`,
    # the one code path that creates the freeze commit. Builder Report has its own
    # command (`architect evidence`) because it is transcribed verbatim from scratch.
    # `frozen: true` sections live above the freeze boundary and are refused once frozen.
    SECTIONS = {
      "grounds" => { heading: "## Grounds", message: "grounds", frozen: true },
      "specification" => { heading: "## Specification", message: "specification", frozen: true },
      "prompt" => { heading: "## Builder Prompt", message: "dispatched", frozen: false },
      "verdict" => { heading: "## Verdict", message: "verdict", frozen: false }
    }.freeze

    # The fixed top-level section headings. Section boundaries are detected against
    # this set (not any "## " line), so a verbatim Builder Report containing its own
    # "## " headings cannot fool the parser.
    KNOWN_HEADINGS = [
      "## Grounds", "## Specification", "## Acceptance Criteria",
      "## Builder Prompt", "## Builder Report", "## Verdict"
    ].freeze

    # Hard per-gate timeout. Generous relative to the full suite (~55s).
    DEFAULT_GATE_TIMEOUT = 900

    # Sentinel written to prompt.md by worktree_add. dispatch refuses to launch on this content.
    PROMPT_STUB = "<!-- ARCHITECT: write this lane's builder prompt here, then dispatch. -->"

    # Inlined settings.json template for `architect init`. Registers a SessionStart
    # hook on the three explicit session-start events (startup/clear/resume) so every
    # space gets auto-regrounding. compact is intentionally omitted — reground on
    # explicit session events, not every compaction cycle.
    SETTINGS_JSON_TEMPLATE = <<~JSON
      {
        "hooks": {
          "SessionStart": [
            {
              "matcher": "startup",
              "hooks": [{"type": "command", "command": "architect", "args": ["ground"]}]
            },
            {
              "matcher": "clear",
              "hooks": [{"type": "command", "command": "architect", "args": ["ground"]}]
            },
            {
              "matcher": "resume",
              "hooks": [{"type": "command", "command": "architect", "args": ["ground"]}]
            }
          ]
        }
      }
    JSON

    def initialize(space:)
      @space = space
    end

    def init!
      handoff_path = space.path.join("architecture", "ARCHITECT.md")
      settings_path = space.path.join(".claude", "settings.json")
      to_add = []

      unless handoff_path.exist?
        FileUtils.mkdir_p(handoff_path.dirname)
        handoff_path.write(render_handoff)
        update_architect_block do |b|
          b.merge("status" => "active", "current_iteration" => nil, "iterations" => [])
        end
        to_add << "architecture/ARCHITECT.md"
        to_add << Space::Core::Space::METADATA_FILE
      end

      unless settings_path.exist?
        FileUtils.mkdir_p(settings_path.dirname)
        settings_path.write(SETTINGS_JSON_TEMPLATE)
        to_add << ".claude/settings.json"
      end

      if to_add.any?
        git_run("-C", space.path.to_s, "add", *to_add)
        msg = to_add.include?("architecture/ARCHITECT.md") ? "Initialize architect project" : "Add architect settings"
        git_run("-C", space.path.to_s, "commit", "-m", msg)
      end

      handoff_path
    end

    # Allocate the next ordinal and scaffold architecture/I<NN>-<iteration>.md.
    def new_iteration!(name)
      block = space.data["project"] || {}
      iterations = block["iterations"] || []
      if iterations.any? { |s| s["name"] == name }
        raise Space::Core::Error, "iteration '#{name}' already exists in space.yaml"
      end

      ordinal = (iterations.map { |s| s["ordinal"] || 0 }.max || 0) + 1
      nn = format("%02d", ordinal)
      rel = "architecture/I#{nn}-#{name}.md"
      path = space.path.join(rel)
      raise Space::Core::Error, "#{rel} already exists" if path.exist?

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

      git_run("-C", space.path.to_s, "add", rel, Space::Core::Space::METADATA_FILE)
      git_run("-C", space.path.to_s, "commit", "-m", "I#{nn}: scaffold #{name}")

      path
    end

    def status
      block = space.data["project"] || {}
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
    def freeze!(iteration, warnings: nil)
      entry = slice_entry(iteration)
      rel = entry["file"]
      path = space.path.join(rel)
      raise Space::Core::Error, "#{rel} does not exist — run `architect new #{iteration}` first" unless path.exist?
      text = path.read
      unless text.match?(/^## Acceptance Criteria/)
        raise Space::Core::Error, "#{rel} has no '## Acceptance Criteria' section — write the Acceptance Criteria before freezing"
      end

      lint_gates!(text, warnings: warnings)

      if entry["freeze_sha"]
        sha = entry["freeze_sha"]
        if frozen_region_changed?(sha, rel)
          raise Space::Core::Error,
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

    # Scaffold the durable, section-numbered project brief at architecture/BRIEF.md
    # and commit it. The brief is the stable cross-iteration address space iterations
    # cite as "BRIEF §N"; it lives outside the per-iteration freeze region.
    def brief_new!(force: false)
      brief_path = space.path.join("architecture", "BRIEF.md")
      if brief_path.exist? && !force
        raise Space::Core::Error, "architecture/BRIEF.md already exists — edit it directly (idempotent guard), or pass --force to overwrite"
      end

      FileUtils.mkdir_p(brief_path.dirname)
      brief_path.write(render_brief)
      git_run("-C", space.path.to_s, "add", "architecture/BRIEF.md")
      git_run("-C", space.path.to_s, "commit", "-m", "Add project brief") if staged_changes?
      brief_path
    end

    # Write one section of the iteration file and commit it with the canonical
    # per-section message, in one call. Refuses to write a frozen section
    # (Grounds/Specification) once the iteration is frozen. Acceptance Criteria is
    # NOT writable here (use freeze); Builder Report is not here (use evidence).
    def write_section!(iteration, section, body:, append: false, lane: nil)
      spec = SECTIONS[section]
      unless spec
        raise Space::Core::Error,
          "Unknown section '#{section}' — one of: #{SECTIONS.keys.join(', ')}. " \
          "(Acceptance Criteria is set by `architect freeze`; Builder Report by `architect evidence`.)"
      end

      entry = slice_entry(iteration)
      rel = entry["file"]
      path = space.path.join(rel)
      raise Space::Core::Error, "#{rel} does not exist — run `architect new #{iteration}` first" unless path.exist?

      if spec[:frozen] && entry["freeze_sha"]
        raise Space::Core::Error,
          "#{spec[:heading]} is frozen for #{iteration} (freeze #{entry["freeze_sha"][0, 8]}) — " \
          "frozen sections are read-only after the freeze commit. Open a new iteration to change the contract."
      end

      block = lane ? "### #{lane}\n\n#{body.strip}" : body.strip
      path.write(replace_section_body(path.read, spec[:heading], block, append: append))

      nn = format("%02d", entry["ordinal"] || 0)
      git_run("-C", space.path.to_s, "add", rel)
      committed = staged_changes?
      git_run("-C", space.path.to_s, "commit", "-m", "I#{nn}: #{spec[:message]}") if committed

      head, = git_capture("-C", space.path.to_s, "rev-parse", "HEAD")
      diffstat, = committed ? git_capture("-C", space.path.to_s, "show", "--stat", "--format=", "HEAD") : [""]
      { section: section, heading: spec[:heading], sha: head.strip, committed: committed, diffstat: diffstat.strip }
    end

    # Write the ## Verdict prose AND record the decision to space.yaml in one commit.
    # decision must be "continue" or "kill".
    def record_verdict!(iteration, decision:, body:)
      unless %w[continue kill].include?(decision)
        raise Space::Core::Error,
          "Invalid verdict decision '#{decision}' — must be one of: continue, kill"
      end

      entry = slice_entry(iteration)
      rel = entry["file"]
      path = space.path.join(rel)
      raise Space::Core::Error, "#{rel} does not exist — run `architect new #{iteration}` first" unless path.exist?

      path.write(replace_section_body(path.read, SECTIONS["verdict"][:heading], body.strip, append: false))

      update_architect_block do |b|
        (b["iterations"] || []).each { |s| s["verdict"] = decision if s["name"] == iteration }
        b
      end

      nn = format("%02d", entry["ordinal"] || 0)
      git_run("-C", space.path.to_s, "add", rel, Space::Core::Space::METADATA_FILE)
      git_run("-C", space.path.to_s, "commit", "-m", "I#{nn}: verdict")

      head, = git_capture("-C", space.path.to_s, "rev-parse", "HEAD")
      { decision: decision, sha: head.strip }
    end

    # Transcribe a lane's scratch report (build/<id>[-<lane>]/report.md) VERBATIM into
    # the Builder Report section and commit. Byte-for-byte: no summarization, no judgment.
    def transcribe_evidence!(iteration, lane: nil)
      entry = slice_entry(iteration)
      rel = entry["file"]
      path = space.path.join(rel)
      raise Space::Core::Error, "#{rel} does not exist — run `architect new #{iteration}` first" unless path.exist?

      id = iteration_id(entry)
      report = space.path.join("build", lane ? "#{id}-#{lane}" : id, "report.md")
      raise Space::Core::Error, "builder report not found: #{report}" unless report.exist?
      raw = report.read
      raise Space::Core::Error, "builder report is empty: #{report}" if raw.strip.empty?

      block = lane ? "### #{lane}\n\n#{raw.rstrip}" : raw.rstrip
      path.write(replace_section_body(path.read, "## Builder Report", block, append: !lane.nil?))

      nn = format("%02d", entry["ordinal"] || 0)
      git_run("-C", space.path.to_s, "add", rel)
      git_run("-C", space.path.to_s, "commit", "-m", "I#{nn}: evidence") if staged_changes?
      head, = git_capture("-C", space.path.to_s, "rev-parse", "HEAD")

      status_line = raw.lines.reverse_each.find { |l| l.strip.start_with?("STATUS:") }&.strip
      { sha: head.strip, lines: raw.lines.count, status_line: status_line, lane: lane }
    end

    # Read the Acceptance Criteria section text, by default from the freeze commit
    # (so the architect quotes the frozen gates, never a drifted working copy).
    def acceptance_criteria(iteration, ref: :freeze)
      entry = slice_entry(iteration)
      rel = entry["file"]
      ref = entry["freeze_sha"] if ref == :freeze
      text =
        if ref
          out, _, st = git_capture("-C", space.path.to_s, "show", "#{ref}:#{rel}")
          raise Space::Core::Error, "could not read #{rel} at #{ref}" unless st.success?
          out
        else
          space.path.join(rel).read
        end
      section_body(text, "## Acceptance Criteria")
    end

    # Integrate ONE architect-judged-passing lane: commit the builder's working tree on
    # the lane branch, then merge --no-ff into the repo's lane/<id> integration branch.
    # Runs NO gates and makes NO pass/fail decision. Refuses a mechanically-failing lane
    # (builder commits / out-of-bounds) and aborts cleanly on a merge conflict.
    def merge_lane!(iteration, lane, message: nil)
      entry = slice_entry(iteration)
      lane_entry = (entry["lanes"] || []).find { |l| l["name"] == lane }
      raise Space::Core::Error, "No lane '#{lane}' recorded for iteration '#{iteration}'" unless lane_entry

      checks = lane_mechanical_checks(entry, lane_entry)
      if checks[:no_builder_commits] == false
        raise Space::Core::Error, "Lane '#{lane}' has builder commits — the worktree is tampered (hard rule 7). Reset and re-dispatch; do not merge."
      end
      if checks[:in_bounds] == false
        raise Space::Core::Error, "Lane '#{lane}' wrote outside its declared touch set — out-of-bounds fails the lane. Reset and re-dispatch."
      end

      repo = lane_entry["repo"]
      repo_path = space.path.join("repos", repo)
      id = iteration_id(entry)
      wt_path = space.path.join(lane_entry["worktree"] || "build/#{id}-#{lane}/wt")
      raise Space::Core::Error, "Worktree directory does not exist: #{wt_path}" unless wt_path.exist?
      base_sha = lane_entry["base_sha"]
      lane_branch = "lane/#{id}-#{lane}"
      integration_branch = project_integration_branch

      status_out, = git_capture("-C", wt_path.to_s, "status", "--porcelain")
      raise Space::Core::Error, "Lane '#{lane}' worktree has no changes to integrate." if status_out.strip.empty?

      git_run("-C", wt_path.to_s, "add", "-A")
      git_run("-C", wt_path.to_s, "commit", "-m", message || "lane #{lane}: integrate")
      integrate_sha_raw, = git_capture("-C", wt_path.to_s, "rev-parse", "HEAD")
      integrate_sha = integrate_sha_raw.strip

      _o, _e, exists = git_capture("-C", repo_path.to_s, "rev-parse", "--verify", "--quiet", integration_branch)
      if exists.success?
        git_run("-C", repo_path.to_s, "checkout", integration_branch)
      else
        git_run("-C", repo_path.to_s, "checkout", "-b", integration_branch, base_sha)
      end

      _mo, merr, mst = git_capture("-C", repo_path.to_s, "merge", "--no-ff", lane_branch, "-m", "Merge #{lane_branch}")
      unless mst.success?
        conflicts, = git_capture("-C", repo_path.to_s, "diff", "--name-only", "--diff-filter=U")
        git_capture("-C", repo_path.to_s, "merge", "--abort")
        raise Space::Core::Error,
          "Merge conflict integrating lane '#{lane}' (#{conflicts.split.join(", ")}) — the lane plan was " \
          "not disjoint = a spec defect. Kill the conflicting lane and re-spec; do not hand-resolve. #{merr.strip}"
      end

      merge_sha, = git_capture("-C", repo_path.to_s, "rev-parse", "HEAD")
      diffstat, = git_capture("-C", repo_path.to_s, "diff", "--stat", "#{base_sha}..HEAD")

      update_architect_block do |b|
        b["integration_branch"] = integration_branch
        (b["iterations"] || []).each do |s|
          next unless s["name"] == iteration
          (s["lanes"] || []).each do |l|
            next unless l["name"] == lane
            l["integration_branch"] = integration_branch
            l["integrate_sha"] = integrate_sha
          end
        end
        b
      end

      { lane: lane, repo: repo, integration_branch: integration_branch,
        merge_sha: merge_sha.strip, base_sha: base_sha, diffstat: diffstat.strip, gates_run: false }
    end

    # Loop merge_lane! over the architect-supplied passing set, in order. Stops on the
    # first conflict (a disjointness defect). Never decides which lanes pass.
    def integrate!(iteration, lanes:, teardown: false)
      raise Space::Core::Error, "No lanes given to integrate" if lanes.nil? || lanes.empty?

      merged = []
      lanes.each do |lane|
        merged << merge_lane!(iteration, lane)
      rescue Space::Core::Error => e
        done = merged.map { |m| m[:lane] }.join(", ")
        raise Space::Core::Error, "Integrated #{done.empty? ? "(none)" : done} then stopped at '#{lane}': #{e.message}"
      end

      if teardown
        id = iteration_id(slice_entry(iteration))
        merged.each do |m|
          worktree_remove(iteration, m[:lane])
          git_capture("-C", space.path.join("repos", m[:repo]).to_s, "branch", "-d", "lane/#{id}-#{m[:lane]}")
        end
      end
      merged
    end

    # Generate the end-of-project PR command(s) for each integrated repo.
    # Writes a PR body to build/land/<repo>-pr-body.md and returns, per repo:
    # { repo:, integration_branch:, body_file:, command:, context: }.
    # Raises Space::Core::Error if nothing has been integrated yet.
    # Side-effect-free: no git write, no push, no gh.
    def land
      b = space.data["project"] || {}
      integration_branch = project_integration_branch

      integrated_lanes = (b["iterations"] || []).flat_map do |s|
        (s["lanes"] || []).filter_map { |l| { iteration: s, lane: l } if l["integration_branch"] }
      end

      raise Space::Core::Error, "nothing integrated yet — integrate a lane before landing" if integrated_lanes.empty?

      repos = integrated_lanes.map { |e| e[:lane]["repo"] }.uniq

      repos.map do |repo|
        body_dir = space.path.join("build", "land")
        FileUtils.mkdir_p(body_dir)
        body_path = body_dir.join("#{repo}-pr-body.md")

        iterations = b["iterations"] || []
        body = +"# #{space.title}\n\nMerges `#{integration_branch}` → `main`.\n\n## Iterations\n\n"
        iterations.each do |s|
          nn = format("%02d", s["ordinal"])
          verdict = s["verdict"] || "—"
          body << "- I#{nn} #{s["name"]} — #{verdict}\n"
        end
        body_path.write(body)

        cmd = %(gh pr create --base main --head #{integration_branch} --title "#{space.title}" --body-file #{body_path})
        context = "# Run from repos/#{repo} on branch #{integration_branch} (gh pushes it)"
        { repo: repo, integration_branch: integration_branch, body_file: body_path.to_s, command: cmd, context: context }
      end
    end

    # Run the iteration's frozen Acceptance Criteria gate commands. Each gate is
    # executed in the resolved cwd (per-gate `cwd` overrides the base dir), under
    # a hard timeout, and evaluated against its `expect` block. Returns an array
    # of result hashes with :status (:pass/:fail) and :reason in addition to the
    # raw :stdout/:stderr/:exit_code. The mechanical verdict belongs here; the AC
    # verdict remains the architect's.
    def run_gates(iteration, lane: nil)
      entry = slice_entry(iteration)
      freeze_sha = entry["freeze_sha"]
      raise Space::Core::Error, "Iteration '#{iteration}' is not frozen — freeze before running gates." unless freeze_sha
      rel = entry["file"]

      text, _, st = git_capture("-C", space.path.to_s, "show", "#{freeze_sha}:#{rel}")
      raise Space::Core::Error, "could not read frozen #{rel} at #{freeze_sha[0, 8]}" unless st.success?
      gates = parse_gates(text)
      raise Space::Core::Error, "no gate commands found in the frozen Acceptance Criteria of #{rel}" if gates.empty?

      lanes = entry["lanes"] || []
      base_dir =
        if lane
          le = lanes.find { |l| l["name"] == lane }
          raise Space::Core::Error, "No lane '#{lane}' recorded for iteration '#{iteration}'" unless le
          space.path.join(le["worktree"] || "build/#{iteration_id(entry)}-#{lane}/wt")
        else
          repo = lanes.first&.dig("repo")
          raise Space::Core::Error, "No lane/repo recorded for '#{iteration}' — cannot resolve a directory to run gates in" unless repo
          space.path.join("repos", repo)
        end
      raise Space::Core::Error, "directory does not exist: #{base_dir}" unless base_dir.exist?

      gates.map do |gate|
        g   = gate.transform_keys(&:to_s)
        dir = g["cwd"] ? space.path.join(g["cwd"]) : base_dir
        raise Space::Core::Error, "directory does not exist: #{dir}" unless dir.exist?

        effective = g["timeout"] || DEFAULT_GATE_TIMEOUT
        captured = capture_with_timeout(g["cmd"], dir: dir, timeout: effective)

        if captured[:timed_out]
          status = :fail
          reason = "timed out after #{effective}s"
        else
          ev     = GateEvaluator.call(stdout: captured[:stdout], exit_code: captured[:exit_code], expect: g["expect"] || {})
          status = ev.pass? ? :pass : :fail
          reason = ev.reason
        end

        { id: g["id"], ac: g["ac"].to_s, cmd: g["cmd"], expect: g["expect"],
          stdout: captured[:stdout], stderr: captured[:stderr], exit_code: captured[:exit_code],
          dir: dir, status: status, reason: reason }
      end
    end

    # Emit grounding reads for the architect's SessionStart hook.
    #
    # Prints to stdout (via the caller), in order:
    #   1. architecture/ARCHITECT.md — always, if present
    #   2. architecture/BRIEF.md    — if present
    #   3. In-flight iteration file — resolved as:
    #        a) space.data["project"]["current_iteration"] entry's file, if it exists on disk
    #        b) highest-ordinal architecture/I<NN>-*.md otherwise
    #        c) nothing if neither
    #
    # WORKTREE GUARD (load-bearing, §1): when session_cwd is inside a builder
    # worktree (<space>/build/<id>/wt/**), returns "" and the caller emits nothing.
    # Builders never receive architect grounding.
    #
    # session_cwd defaults to Dir.pwd; callers may inject a path for testing or
    # to pass the value received from the hook's stdin JSON {"cwd": "..."}.
    def ground(session_cwd: nil)
      cwd = File.expand_path(session_cwd || Dir.pwd)
      build_root = space.path.join("build").to_s
      if cwd.start_with?("#{build_root}/") && cwd.match?(%r{/build/[^/]+/wt(/|\z)})
        return ""
      end

      parts = []

      architect_path = space.path.join("architecture", "ARCHITECT.md")
      parts << "=== architecture/ARCHITECT.md ===\n\n#{architect_path.read}" if architect_path.exist?

      brief_path = space.path.join("architecture", "BRIEF.md")
      parts << "=== architecture/BRIEF.md ===\n\n#{brief_path.read}" if brief_path.exist?

      iter_path = resolve_inflight_iteration
      if iter_path
        rel = iter_path.relative_path_from(space.path).to_s
        parts << "=== #{rel} ===\n\n#{iter_path.read}"
      end

      parts.join("\n")
    end

    def worktree_add(repo, iteration, lane, base: nil, harness: "claude-code", model: nil, variant: false, effort: nil, touch: nil)
      if harness.to_s == "opencode" && (model.nil? || model == Harness::CLAUDE_DEFAULT_MODEL)
        raise Space::Core::Error,
          "Pass --model when using --harness opencode " \
          "(#{Harness::CLAUDE_DEFAULT_MODEL} is a Claude model ID, not valid for opencode — " \
          "try e.g. fireworks-ai/accounts/fireworks/models/glm-5p2)"
      end
      if effort && harness.to_s != "opencode"
        raise Space::Core::Error,
          "effort is opencode-only (sets opencode reasoningEffort) — " \
          "set effort only on opencode lanes (harness: opencode)"
      end

      entry = slice_entry(iteration)
      repo_path = space.path.join("repos", repo)
      raise Space::Core::Error, "repos/#{repo} does not exist" unless repo_path.exist?

      id = iteration_id(entry)
      wt_path   = space.path.join("build", "#{id}-#{lane}", "wt")
      build_dir = space.path.join("build", "#{id}-#{lane}")
      FileUtils.mkdir_p(wt_path.dirname)

      base_ref = base || "HEAD"
      base_sha, _, wt_status = git_capture("-C", repo_path.to_s, "rev-parse", base_ref)
      raise Space::Core::Error, "Could not resolve base ref '#{base_ref}' in #{repo}" unless wt_status.success?
      base_sha = base_sha.strip

      branch = "lane/#{id}-#{lane}"

      # Guard: an existing directory that is not a registered worktree is ambiguous — refuse.
      if wt_path.exist? && !worktree_registered?(repo_path, wt_path)
        raise Space::Core::Error,
          "#{wt_path} exists but is not a registered git worktree of #{repo} — " \
          "resolve manually before re-running worktree_add"
      end

      # Skip git worktree add when the branch and worktree already exist (idempotent re-run).
      unless branch_exists?(repo_path, branch) && worktree_registered?(repo_path, wt_path)
        git_run("-C", repo_path.to_s, "worktree", "add", wt_path.to_s, "-b", branch, base_sha)
      end

      # Seed prompt.md with a placeholder stub so the architect has a place to write the prompt.
      # Never overwrite an existing file (real prompt or stub from a prior run).
      prompt_path = build_dir.join("prompt.md")
      prompt_path.write("#{PROMPT_STUB}\n") unless prompt_path.exist?

      new_fields = {
        "name" => lane,
        "repo" => repo,
        "base_sha" => base_sha,
        "worktree" => "build/#{id}-#{lane}/wt",
        "integration_branch" => nil,
        "harness" => harness.to_s,
        "model" => model,
        "variant" => variant
      }
      new_fields["effort"]    = effort         if effort
      new_fields["touch_set"] = Array(touch)   if touch && !Array(touch).empty?

      update_architect_block do |b|
        (b["iterations"] || []).each do |s|
          next unless s["name"] == iteration
          lanes = s["lanes"] || []
          existing = lanes.find { |l| l["name"] == lane }
          if existing
            existing.merge!(new_fields)
          else
            lanes << new_fields
            s["lanes"] = lanes
          end
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
      variant_lanes = (entry["lanes"] || []).select { |l| l["variant"] }
      raise Space::Core::Error, "Iteration '#{iteration}' has no variant set — nothing to promote" if variant_lanes.empty?

      names = variant_lanes.map { |l| l["name"] }
      raise Space::Core::Error, "Cannot promote '#{winner}' — not a variant lane of iteration '#{iteration}'" unless names.include?(winner)
      discarded_names = names - [winner]

      update_architect_block do |b|
        (b["iterations"] || []).each do |s|
          next unless s["name"] == iteration
          s["winner"] = winner
          (s["lanes"] || []).each do |l|
            next unless l["variant"]
            l["discarded"] = (l["name"] != winner)
          end
        end
        b
      end

      { winner: winner, discarded: discarded_names }
    end

    # Read-only side-by-side view of an iteration's variant set, reading ONLY the
    # durable records in space.yaml. Returns a structured hash; the CLI renders it.
    def variant_compare(iteration)
      entry = slice_entry(iteration)
      variant_lanes = (entry["lanes"] || []).select { |l| l["variant"] }
      raise Space::Core::Error, "Iteration '#{iteration}' has no variant set — nothing to compare" if variant_lanes.empty?

      winner = entry["winner"]
      {
        winner:     winner,
        freeze_sha: entry["freeze_sha"],
        variants: variant_lanes.map do |l|
          {
            name:               l["name"],
            harness:            l["harness"] || "claude-code",
            model:              l["model"],
            effort:             l["effort"],
            base_sha:           l["base_sha"],
            integration_branch: l["integration_branch"],
            status:             winner.nil? ? "pending" : (l["name"] == winner ? "winner" : "discarded")
          }
        end
      }
    end

    def worktree_remove(iteration, lane)
      entry = slice_entry(iteration)
      lane_entry = (entry["lanes"] || []).find { |l| l["name"] == lane }
      raise Space::Core::Error, "No lane '#{lane}' recorded for iteration '#{iteration}'" unless lane_entry

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
          (s["lanes"] || []).each { |l| l["worktree"] = nil if l["name"] == lane }
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
      (entry["lanes"] || []).map do |lane|
        { lane: lane["name"], repo: lane["repo"], checks: lane_mechanical_checks(entry, lane) }
      end
    end

    def dispatch(iteration, lane, model: nil, max_turns: 200,
                 claude_bin: nil, harness: nil, opencode_bin: nil, effort: nil, detach: false,
                 push_url: nil, push_token: nil, push_host: nil, run_creator: nil,
                 push_client: nil, timeout: nil)
      raise Space::Core::Error, "Specify --push-host or --push-url, not both" if push_host && push_url
      raise Space::Core::Error, "--push-host requires --push-token"           if push_host && !push_token
      raise Space::Core::Error, "--detach cannot be combined with --push-url or --push-host" \
        if detach && (push_url || push_host)

      entry = slice_entry(iteration)
      lane_entry = (entry["lanes"] || []).find { |l| l["name"] == lane }
      raise Space::Core::Error, "No lane '#{lane}' recorded for iteration '#{iteration}'" unless lane_entry

      resolved_harness = harness || lane_entry["harness"] || "claude-code"
      resolved_model   = model   || lane_entry["model"]   || Harness::CLAUDE_DEFAULT_MODEL
      resolved_effort  = effort  || lane_entry["effort"]

      raise Space::Core::Error, "--push-host is only supported with the claude-code harness" \
        if push_host && resolved_harness != "claude-code"

      id = iteration_id(entry)
      wt_path = space.path.join(lane_entry["worktree"] || "build/#{id}-#{lane}/wt")
      raise Space::Core::Error, "Worktree directory does not exist: #{wt_path}" unless wt_path.exist?

      build_dir    = space.path.join("build", "#{id}-#{lane}")
      prompt_path  = build_dir.join("prompt.md")
      run_log_path = build_dir.join("run.jsonl")
      report_path  = build_dir.join("report.md")
      raise Space::Core::Error, "prompt.md not found: #{prompt_path}" unless prompt_path.exist?

      prompt_content = prompt_path.read.strip
      raise Space::Core::Error, "Write this lane's prompt to #{prompt_path} before dispatching." \
        if prompt_content.empty? || prompt_content == PROMPT_STUB.strip

      bin = resolved_harness == "claude-code" ? claude_bin : opencode_bin
      harness_obj = Harness.for(resolved_harness, model: resolved_model, max_turns: max_turns,
                                                  bin: bin, config_dir: build_dir, effort: resolved_effort)

      if detach
        pid = harness_obj.run_detached(
          prompt_path:  prompt_path,
          run_log_path: run_log_path,
          chdir:        wt_path
        )
        { pid: pid, run_log: run_log_path, report: report_path, worktree: wt_path }
      else
        created_run_id = nil
        if push_host
          creator        = run_creator || RunCreator.new(push_host, push_token)
          created_run_id = creator.create
          push_url       = "#{push_host.chomp('/')}/runs/#{created_run_id}/ingest"
        end

        run_kwargs = { prompt_path: prompt_path, run_log_path: run_log_path, chdir: wt_path }
        run_kwargs[:timeout] = timeout if timeout
        if resolved_harness == "claude-code"
          run_kwargs[:push_url]    = push_url    if push_url
          run_kwargs[:push_token]  = push_token  if push_token
          run_kwargs[:push_client] = push_client if push_client
        end
        exit_code = harness_obj.run(**run_kwargs)

        result = { exit_code: exit_code, run_log: run_log_path, report: report_path, worktree: wt_path }
        result[:timed_out]      = true           if exit_code == Harness::ClaudeCodeHarness::TIMEOUT_EXIT_CODE
        result[:created_run_id] = created_run_id if created_run_id
        result[:push_url]       = push_url       if push_url
        result
      end
    end

    private

    attr_reader :space

    # Resolve the in-flight iteration file for ground output.
    # Rule: (a) current_iteration from project block → entry's file if it exists on disk,
    #        (b) else highest-ordinal architecture/I<NN>-*.md,
    #        (c) else nil.
    def resolve_inflight_iteration
      block = space.data["project"] || {}
      arch_dir = space.path.join("architecture")
      return nil unless arch_dir.exist?

      current = block["current_iteration"]
      if current
        entry = (block["iterations"] || []).find { |s| s["name"] == current }
        if entry && entry["file"]
          path = space.path.join(entry["file"])
          return path if path.exist?
        end
      end

      candidates = arch_dir.children.select { |f| f.basename.to_s.match?(/\AI\d+-.+\.md\z/) }
      return nil if candidates.empty?
      candidates.max_by { |f| f.basename.to_s[/\AI(\d+)/, 1].to_i }
    end

    # Spawn cmd in dir with pgroup: true, writing stdout/stderr to temp files so
    # pipe buffers can never block. Polls with WNOHANG; kills the process group on
    # timeout. Returns { stdout:, stderr:, exit_code:, timed_out: }.
    def capture_with_timeout(cmd, dir:, timeout:)
      out_f = Tempfile.new(["gate-stdout", ".log"])
      err_f = Tempfile.new(["gate-stderr", ".log"])
      pid   = Process.spawn(cmd, pgroup: true, chdir: dir.to_s, out: out_f.path, err: err_f.path)

      deadline  = Time.now + timeout
      status    = nil
      timed_out = false

      until status
        if Time.now > deadline
          timed_out = true
          Process.kill("TERM", -pid) rescue nil
          sleep 0.5
          Process.kill("KILL", -pid) rescue nil
          Process.wait(pid) rescue nil
          break
        end
        _, st = Process.waitpid2(pid, Process::WNOHANG)
        if st
          status = st
        else
          sleep 0.05
        end
      end

      out_f.rewind; err_f.rewind
      { stdout: out_f.read, stderr: err_f.read, exit_code: status&.exitstatus, timed_out: timed_out }
    ensure
      out_f&.close!
      err_f&.close!
    end

    def iteration_id(entry)
      "I#{format('%02d', entry['ordinal'])}-#{entry['name']}"
    end

    def project_integration_branch
      b = space.data["project"] || {}
      return b["integration_branch"] if b["integration_branch"]
      slug = space.title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
      "project/#{slug}"
    end

    def slice_entry(iteration)
      block = space.data["project"] || {}
      entry = (block["iterations"] || []).find { |s| s["name"] == iteration }
      raise Space::Core::Error, "Iteration '#{iteration}' not recorded in space.yaml — run `architect new #{iteration}` first" unless entry
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

    # The four per-lane post-flight checks, shared by `verify` (reports) and
    # `merge_lane!` (refuses on failure) so the two can never drift.
    def lane_mechanical_checks(entry, lane)
      freeze_sha = entry["freeze_sha"]
      rel = entry["file"]
      lane_name = lane["name"]
      base_sha = lane["base_sha"]
      wt_path = space.path.join(lane["worktree"] || "build/#{iteration_id(entry)}-#{lane_name}/wt")
      touch_set = lane["touch_set"] || []

      checks = {}

      # (a) frozen sections of the iteration file untouched since freeze
      checks[:frozen_untouched] = (!frozen_region_changed?(freeze_sha, rel) if freeze_sha && rel)

      # (b) no builder commits in the worktree (the architect's integrate commit is excluded)
      log_out, = git_capture("-C", wt_path.to_s, "log", "--format=%H", "#{base_sha}..")
      commit_shas = log_out.strip.split("\n").map(&:strip).reject(&:empty?)
      recorded_integrate = lane["integrate_sha"]&.strip
      builder_shas = recorded_integrate ? commit_shas.reject { |s| s == recorded_integrate } : commit_shas
      checks[:no_builder_commits] = builder_shas.empty?

      # (c) builder's scratch report exists and is non-empty
      report = space.path.join("build", "#{iteration_id(entry)}-#{lane_name}", "report.md")
      checks[:report_exists] = report.exist? && !report.read.strip.empty?

      # (d) in-bounds: changed paths ⊆ touch_set (:no_touch_set if none recorded)
      checks[:in_bounds] = if touch_set.empty?
        :no_touch_set
      else
        # -z: NUL-delimited; renames emit new_path NUL old_path — include both
        status_out, = git_capture("-C", wt_path.to_s, "status", "--porcelain", "-z")
        changed = []
        entries = status_out.split("\0")
        i = 0
        while i < entries.length
          entry = entries[i]
          i += 1
          next if entry.empty? || entry.length < 3
          code = entry[0, 2]
          path = entry[3..]
          changed << path if path && !path.empty?
          next unless code[0] == "R" || code[0] == "C"
          orig = entries[i]
          i += 1
          changed << orig if orig && !orig.empty?
        end
        fnm = File::FNM_PATHNAME | File::FNM_EXTGLOB
        changed.all? { |f| touch_set.any? { |g| File.fnmatch(g, f, fnm) } }
      end

      checks
    end

    # Replace (or, with append:, extend) the body of a "## Heading" section, leaving
    # every other section byte-untouched. Append replaces a placeholder body (only a
    # template comment) the first time, then stacks subsections after it.
    def replace_section_body(text, heading, new_block, append:)
      lines = text.lines
      start = lines.index { |l| l.chomp == heading }
      raise Space::Core::Error, "section heading '#{heading}' not found in iteration file" unless start

      finish = ((start + 1)...lines.length).find { |i| KNOWN_HEADINGS.include?(lines[i].chomp) } || lines.length
      body = lines[(start + 1)...finish].join

      new_body =
        if append && !placeholder_body?(body)
          "#{body.strip}\n\n#{new_block.strip}"
        else
          new_block.strip
        end

      prefix = lines[0..start].join.rstrip
      suffix = lines[finish..].to_a.join.strip
      parts = [prefix, "", new_body]
      parts += ["", suffix] unless suffix.empty?
      "#{parts.join("\n")}\n"
    end

    # A section body is a placeholder when it holds nothing but a leading HTML
    # comment (the scaffold's guidance) and whitespace.
    def placeholder_body?(body)
      body.strip.sub(/\A<!--.*?-->/m, "").strip.empty?
    end

    # The text between "## Heading" and the next "## " heading (nil if absent).
    def section_body(text, heading)
      lines = text.lines
      start = lines.index { |l| l.chomp == heading }
      return nil unless start
      finish = ((start + 1)...lines.length).find { |i| KNOWN_HEADINGS.include?(lines[i].chomp) } || lines.length
      lines[(start + 1)...finish].join.strip
    end

    # Extract and parse the fenced ```gates block from the Acceptance Criteria section.
    # Returns an array of gate hashes (string-keyed). Returns [] when the block is
    # absent, empty, or contains only YAML comments.
    def parse_gates(text)
      body = section_body(text, "## Acceptance Criteria")
      return [] unless body
      match = body.match(/^```gates\n(.*?)^```/m)
      return [] unless match
      parsed = YAML.safe_load(match[1], aliases: false)
      parsed.is_a?(Array) ? parsed : []
    end

    # Lint the gates block in the given iteration file text. Raises Space::Core::Error
    # with aggregated messages on failure. Absent/empty gates appends a warning to
    # the optional warnings array but does not fail.
    def lint_gates!(text, warnings: nil)
      gates = begin
        parse_gates(text)
      rescue Psych::SyntaxError => e
        raise Space::Core::Error, "ill-formed gates block: #{e.message}"
      end
      if gates.empty?
        warnings << "no gates — this iteration is prose-judged only" if warnings
        return
      end
      result = GateLint.call(gates)
      return if result.success?
      raise Space::Core::Error, "ill-formed gates block:\n#{result.failure.join("\n")}"
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

    def render_brief
      @_title = space.data["title"] || space.id
      @_repos = space.repos
      render_template("brief.md.erb")
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
      block = space.data["project"] || { "status" => "active", "current_iteration" => nil, "iterations" => [] }
      space.data["project"] = yield(block)
      space.save
    end

    def git_run(*args)
      out, err, status = Open3.capture3("git", *args)
      return if status.success?
      output = [out, err].map(&:strip).reject(&:empty?).join(" ")
      raise Space::Core::Error, "git #{args.join(' ')} failed: #{output}"
    end

    def git_capture(*args)
      Open3.capture3("git", *args)
    end

    def branch_exists?(repo_path, branch)
      _, _, st = git_capture("-C", repo_path.to_s, "rev-parse", "--verify", branch)
      st.success?
    end

    def worktree_registered?(repo_path, wt_path)
      out, _, _ = git_capture("-C", repo_path.to_s, "worktree", "list", "--porcelain")
      real = File.exist?(wt_path.to_s) ? File.realpath(wt_path.to_s) : wt_path.to_s
      out.lines.any? { |l| l.start_with?("worktree ") && l.chomp.delete_prefix("worktree ") == real }
    end
  end
end

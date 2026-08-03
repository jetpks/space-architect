# frozen_string_literal: true

require "yaml"
require "erb"
require "open3"
require "fileutils"
require "pathname"
require "tempfile"
require "time"
require "digest"
require "shellwords"

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
    # Builder Report has its own command (`architect evidence`) because it is
    # transcribed verbatim from scratch.
    # `frozen: true` sections live above the freeze boundary and are refused once frozen.
    SECTIONS = {
      "grounds" => { heading: "## Grounds", message: "grounds", prefix: "grounds", frozen: true },
      "specification" => { heading: "## Specification", message: "specification", prefix: "spec", frozen: true },
      "acceptance-criteria" => { heading: "## Acceptance Criteria", message: "acceptance criteria", prefix: "ac", frozen: true },
      "prompt" => { heading: "## Builder Prompt", message: "dispatched", prefix: "prompt", frozen: false },
      "verdict" => { heading: "## Verdict", message: "verdict", prefix: "verdict", frozen: false }
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

    # The scaffold's untouched placeholder AC1 line — templates/iteration.md.erb's
    # Acceptance Criteria section (named, not line-numbered: a pinned line number
    # here has already drifted twice). Pinned by contract with the authoring
    # lane, which is forbidden from changing it, precisely so freeze!'s #73
    # hard-refuse (below) can key on it.
    AC1_PLACEHOLDER = "**AC1.** ..."

    # Rehearsal's BROKEN heuristic (I09/AC5): a command-not-found exit code or a
    # shell parse failure, distinct from a clean non-zero (RED — the gate
    # discriminates). Advisory, not authoritative — see #classify_rehearsal.
    BROKEN_STDERR_PATTERN = /\bsyntax error\b|unexpected end of file|unexpected eof/i

    # I09/AC9(b): a gate `cmd` that carries a literal 'repos/<name>/' prefix
    # with no `cwd` — legal, occasionally correct, but usually a leftover
    # space-root-relative path since `cmd` already resolves against the repo tree.
    BARE_REPO_PREFIX = %r{(?<![\w./-])repos/[^/\s'"]+/}

    # Legacy sentinel: worktree_add used to seed prompt.md with this placeholder
    # (dropped — the blind-overwrite tripped harness read-before-write guards, #48).
    # dispatch still refuses to launch on this content, so stubs in old spaces
    # can't reach a builder.
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

    def init!(message: nil)
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
        default = to_add.include?("architecture/ARCHITECT.md") ? "Initialize architect project" : "Add architect settings"
        git_run("-C", space.path.to_s, "commit", "-m", compose_message("init:", default, message))
      end

      handoff_path
    end

    # Allocate the next ordinal and scaffold architecture/I<NN>-<iteration>.md.
    def new_iteration!(name, message: nil)
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
      git_run("-C", space.path.to_s, "commit", "-m",
        compose_message("I#{nn} scaffold:", "I#{nn}: scaffold #{name}", message))

      path
    end

    def status
      block = space.data["project"] || {}
      architecture_dir = space.path.join("architecture")
      iteration_files = if architecture_dir.exist?
        # paths:exempt - the /\AI\d+-.+\.md\z/ filter structurally cannot match a dotfile-prefixed name, so raw enumeration is already dotfile-safe here
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
    # With force: true, re-freezes a changed frozen region if no lane is dispatched yet.
    def freeze!(iteration, warnings: nil, message: nil, force: false, skip_rehearse_reason: nil)
      entry = slice_entry(iteration)
      rel = entry["file"]
      path = space.path.join(rel)
      raise Space::Core::Error, "#{rel} does not exist — run `architect new #{iteration}` first" unless path.exist?
      text = path.read
      unless text.match?(/^## Acceptance Criteria/)
        raise Space::Core::Error, "#{rel} has no '## Acceptance Criteria' section — write the Acceptance Criteria before freezing"
      end

      lint_gates!(text, warnings: warnings)
      lint_lanes!(text)

      if untouched_ac_placeholder?(text)
        raise Space::Core::Error,
          "#{rel}'s Acceptance Criteria still carries the scaffold placeholder '#{AC1_PLACEHOLDER}' with no " \
          "active gate — write the real Acceptance Criteria (a hand-authored prose-only AC without the " \
          "placeholder still freezes) before freezing."
      end

      if skip_rehearse_reason
        raise Space::Core::Error, "--skip-rehearse requires a non-empty REASON" if skip_rehearse_reason.to_s.strip.empty?
      else
        ensure_rehearsed!(iteration, entry, text)
      end

      if entry["freeze_sha"]
        sha = entry["freeze_sha"]
        if frozen_region_changed?(sha, rel)
          if force
            dispatched_guard!(entry)
            # fall through to commit path to re-freeze with new sha
          else
            raise Space::Core::Error,
              "Frozen sections of #{rel} changed since freeze #{sha[0, 8]} — " \
              "refusing to re-freeze. Restore them to their frozen state or use a new iteration."
          end
        else
          return sha
        end
      end

      files = [rel]
      files << "architecture/ARCHITECT.md" if space.path.join("architecture", "ARCHITECT.md").exist?
      nn = format("%02d", entry["ordinal"] || 0)
      git_capture("-C", space.path.to_s, "commit", "-m",
        compose_message("I#{nn} freeze:", "I#{nn}: acceptance criteria (freeze)", message), "--", *files)

      sha, = git_capture("-C", space.path.to_s, "rev-parse", "HEAD")
      sha = sha.strip

      declared = parse_lanes(text)
      update_architect_block do |b|
        b["current_iteration"] = iteration
        (b["iterations"] || []).each do |s|
          next unless s["name"] == iteration
          s["freeze_sha"] = sha
          s["verdict"] ||= "pending"
          s["rehearsal_skip_reason"] = skip_rehearse_reason.strip if skip_rehearse_reason
          lanes = s["lanes"] || []
          declared.each do |d|
            fields = { "name" => d["name"], "repo" => d["repo"], "touch_set" => Array(d["touch"]) }
            existing = lanes.find { |l| l["name"] == d["name"] }
            existing ? existing.merge!(fields) : lanes << fields
          end
          s["lanes"] = lanes
        end
        b
      end

      git_run("-C", space.path.to_s, "commit", "-m",
        compose_message("I#{nn} freeze:", "I#{nn}: record freeze sha", message), "--", Space::Core::Space::METADATA_FILE)

      sha
    end

    # Scaffold the durable, section-numbered project brief at architecture/BRIEF.md
    # and commit it. The brief is the stable cross-iteration address space iterations
    # cite as "BRIEF §N"; it lives outside the per-iteration freeze region. With
    # content, writes the authored brief instead of the placeholder template.
    def brief_new!(force: false, content: nil, message: nil)
      brief_path = space.path.join("architecture", "BRIEF.md")
      if brief_path.exist? && !force
        raise Space::Core::Error, "architecture/BRIEF.md already exists — edit it directly (idempotent guard), or pass --force to overwrite"
      end

      FileUtils.mkdir_p(brief_path.dirname)
      brief_path.write(content || render_brief)
      git_run("-C", space.path.to_s, "add", "architecture/BRIEF.md")
      if staged_changes?
        git_run("-C", space.path.to_s, "commit", "-m", compose_message("brief:", "Add project brief", message))
      end
      brief_path
    end

    # Write one section of the iteration file and commit it with the canonical
    # per-section message, in one call. Refuses to write a frozen section
    # (Grounds/Specification/Acceptance Criteria) once the iteration is frozen.
    # With force: true, writes a frozen section if no lane is dispatched yet.
    # Builder Report is not here (use evidence).
    def write_section!(iteration, section, body:, append: false, lane: nil, message: nil, force: false)
      spec = SECTIONS[section]
      unless spec
        raise Space::Core::Error,
          "Unknown section '#{section}' — one of: #{SECTIONS.keys.join(', ')}. " \
          "(Builder Report is written by `architect evidence`.)"
      end

      entry = slice_entry(iteration)
      rel = entry["file"]
      path = space.path.join(rel)
      raise Space::Core::Error, "#{rel} does not exist — run `architect new #{iteration}` first" unless path.exist?

      if spec[:frozen] && entry["freeze_sha"]
        if force
          dispatched_guard!(entry)
        else
          raise Space::Core::Error,
            "#{spec[:heading]} is frozen for #{iteration} (freeze #{entry["freeze_sha"][0, 8]}) — " \
            "frozen sections are read-only after the freeze commit. Open a new iteration to change the contract."
        end
      end

      block = lane ? "### #{lane}\n\n#{body.strip}" : body.strip
      new_text = replace_section_body(path.read, spec[:heading], block, append: append)
      lint_gates!(new_text) if section == "acceptance-criteria"
      path.write(new_text)

      nn = format("%02d", entry["ordinal"] || 0)
      _o, _e, cst = git_capture("-C", space.path.to_s, "commit", "-m",
        compose_message("I#{nn} #{spec[:prefix]}:", "I#{nn}: #{spec[:message]}", message), "--", rel)
      committed = cst.success?
      show_out, = git_capture("-C", space.path.to_s, "show", "--stat", "--format=%H", "HEAD")
      show_lines = show_out.to_s.lines
      sha = show_lines.first&.strip || ""
      diffstat = committed ? show_lines.drop(1).join.strip : ""
      { section: section, heading: spec[:heading], sha: sha, committed: committed, diffstat: diffstat }
    end

    # Write the ## Verdict prose AND record the decision to space.yaml in one commit.
    # decision must be "continue" or "kill".
    def record_verdict!(iteration, decision:, body:, message: nil)
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
      git_run("-C", space.path.to_s, "commit", "-m",
        compose_message("I#{nn} verdict:", "I#{nn}: verdict", message), "--", rel, Space::Core::Space::METADATA_FILE)

      head, = git_capture("-C", space.path.to_s, "rev-parse", "HEAD")
      { decision: decision, sha: head.strip }
    end

    # Transcribe a lane's scratch report (build/<id>[-<lane>]/report.md) VERBATIM into
    # the Builder Report section and commit. Byte-for-byte: no summarization, no judgment.
    # Re-transcribing a lane replaces its existing "### <lane>" subsection in place
    # (preserving the order lanes were already transcribed in) instead of appending a
    # duplicate; a lane not yet present still appends.
    def transcribe_evidence!(iteration, lane: nil, message: nil)
      entry = slice_entry(iteration)
      rel = entry["file"]
      path = space.path.join(rel)
      raise Space::Core::Error, "#{rel} does not exist — run `architect new #{iteration}` first" unless path.exist?

      id = iteration_id(entry)
      report = space.path.join("build", lane ? "#{id}-#{lane}" : id, "report.md")
      raise Space::Core::Error, "builder report not found: #{report}" unless report.exist?
      raw = report.read
      raise Space::Core::Error, "builder report is empty: #{report}" if raw.strip.empty?

      text = path.read
      new_body =
        if lane
          lane_names = (entry["lanes"] || []).map { |l| l["name"] }
          replace_lane_report(section_body(text, "## Builder Report").to_s, lane, raw.rstrip, lane_names)
        else
          raw.rstrip
        end
      path.write(replace_section_body(text, "## Builder Report", new_body, append: false))

      nn = format("%02d", entry["ordinal"] || 0)
      git_capture("-C", space.path.to_s, "commit", "-m",
        compose_message("I#{nn} evidence:", "I#{nn}: evidence", message), "--", rel)
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
    #
    # accept_bounds_reason overrides ONLY the in-bounds check — never no_builder_commits,
    # which stays an unconditional refusal (a builder commit is tampering, not an authoring
    # defect the architect can rule on). Modeled on freeze!'s --skip-rehearse: a non-empty
    # REASON is required whenever passed, recorded in space.yaml beside the lane, and
    # returned for the caller to echo — the override can never be silent. Recorded only
    # for THIS lane, and only when its in-bounds check actually failed — integrate! passes
    # the same reason to every lane in the set, but a lane that was already in bounds gets
    # neither the record nor the echo.
    def merge_lane!(iteration, lane, message: nil, commit_mode: nil, into: nil, accept_bounds_reason: nil)
      if accept_bounds_reason
        raise Space::Core::Error, "--accept-bounds requires a non-empty REASON" if accept_bounds_reason.to_s.strip.empty?
      end

      entry = slice_entry(iteration)
      lane_entry = (entry["lanes"] || []).find { |l| l["name"] == lane }
      raise Space::Core::Error, "No lane '#{lane}' recorded for iteration '#{iteration}'" unless lane_entry
      lane_entry = ensure_lane_materialized(iteration, lane)

      checks = lane_mechanical_checks(entry, lane_entry, commit_mode: commit_mode)
      if checks[:no_builder_commits] == false
        raise Space::Core::Error, "Lane '#{lane}' has builder commits — the worktree is tampered (hard rule 7). Reset and re-dispatch; do not merge."
      end
      if checks[:in_bounds] == false && !accept_bounds_reason
        raise Space::Core::Error, "Lane '#{lane}' wrote outside its declared touch set — out-of-bounds fails the lane. Reset " \
          "and re-dispatch, or `architect integrate #{iteration} --lanes #{lane} --accept-bounds REASON` to override when " \
          "the touch-set declaration itself is the defect."
      end

      repo = lane_entry["repo"]
      repo_path = space.path.join("repos", repo)
      id = iteration_id(entry)
      wt_path = space.path.join(lane_entry["worktree"] || "build/#{id}-#{lane}/wt")
      raise Space::Core::Error, "Worktree directory does not exist: #{wt_path}" unless wt_path.exist?
      base_sha = lane_entry["base_sha"]
      lane_branch = "lane/#{id}-#{lane}"
      integration_branch = into || project_integration_branch

      status_out, = git_capture("-C", wt_path.to_s, "status", "--porcelain")
      raise Space::Core::Error, "Lane '#{lane}' worktree has no changes to integrate." if status_out.strip.empty?

      git_run("-C", wt_path.to_s, "add", "-A")
      git_run("-C", wt_path.to_s, "commit", "-m",
        compose_message("lane #{lane}:", "lane #{lane}: integrate", message))
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
        conflict_files = conflicts.split
        lane_touch_set = lane_entry["touch_set"] || []
        outside = conflict_files.reject { |f| in_touch_set?(f, lane_touch_set) }
        if !lane_touch_set.empty? && outside.empty?
          raise Space::Core::Error,
            "Merge conflict integrating lane '#{lane}' (#{conflict_files.join(", ")}) — the lane plan was " \
            "not disjoint = a spec defect. Kill the conflicting lane and re-spec; do not hand-resolve. #{merr.strip}"
        else
          raise Space::Core::Error,
            "Merge conflict integrating lane '#{lane}' (#{conflict_files.join(", ")}) — conflicting files " \
            "are outside the lane's touch set; this looks like a branch mismatch: the lane is being merged " \
            "into '#{integration_branch}'. Use --into <branch> to target the correct branch. #{merr.strip}"
        end
      end

      merge_sha, = git_capture("-C", repo_path.to_s, "rev-parse", "HEAD")
      diffstat, = git_capture("-C", repo_path.to_s, "diff", "--stat", "#{base_sha}..HEAD")

      bounds_override_reason = accept_bounds_reason.strip if accept_bounds_reason && checks[:in_bounds] == false

      update_architect_block do |b|
        b["integration_branch"] = integration_branch
        (b["iterations"] || []).each do |s|
          next unless s["name"] == iteration
          (s["lanes"] || []).each do |l|
            next unless l["name"] == lane
            l["integration_branch"] = integration_branch
            l["integrate_sha"] = integrate_sha
            l["bounds_override_reason"] = bounds_override_reason if bounds_override_reason
          end
        end
        b
      end

      { lane: lane, repo: repo, integration_branch: integration_branch, merge_sha: merge_sha.strip,
        base_sha: base_sha, diffstat: diffstat.strip, gates_run: false,
        bounds_override_reason: bounds_override_reason }
    end

    # Loop merge_lane! over the architect-supplied passing set, in order. Stops on the
    # first conflict (a disjointness defect). Never decides which lanes pass. With no
    # lanes and teardown: true, tears down every lane recorded for the iteration instead
    # (the second, teardown-only call in the loop's integrate-then-teardown rhythm).
    def integrate!(iteration, lanes: nil, teardown: false, message: nil, commit_mode: nil, into: nil, accept_bounds_reason: nil)
      lanes = Array(lanes)
      return teardown_lanes!(iteration, slice_entry(iteration)["lanes"] || []) if lanes.empty? && teardown
      raise Space::Core::Error, "No lanes given to integrate" if lanes.empty?

      merged = []
      lanes.each do |lane|
        merged << merge_lane!(iteration, lane, message: message, commit_mode: commit_mode, into: into,
          accept_bounds_reason: accept_bounds_reason)
      rescue Space::Core::Error => e
        done = merged.map { |m| m[:lane] }.join(", ")
        raise Space::Core::Error, "Integrated #{done.empty? ? "(none)" : done} then stopped at '#{lane}': #{e.message}"
      end

      teardown_lanes!(iteration, merged) if teardown
      merged
    end

    # Run the iteration's frozen Acceptance Criteria gate commands. Each gate is
    # executed in the resolved cwd (per-gate `cwd` overrides the base dir), under
    # a hard timeout, and evaluated against its `expect` block. Returns an array
    # of result hashes with :status (:pass/:fail) and :reason in addition to the
    # raw :stdout/:stderr/:exit_code. The mechanical verdict belongs here; the AC
    # verdict remains the architect's. WHERE the gate text comes from (the frozen
    # commit) is resolved here; HOW gates execute is #execute_gates, shared
    # byte-for-byte with #rehearse so the two can never run gates through
    # different instruments (I09/AC3).
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
      repo_root = nil
      base_dir =
        if lane
          le = lanes.find { |l| l["name"] == lane }
          raise Space::Core::Error, "No lane '#{lane}' recorded for iteration '#{iteration}'" unless le
          le = ensure_lane_materialized(iteration, lane)
          repo_root = le["repo"] ? space.path.join("repos", le["repo"]) : nil
          space.path.join(le["worktree"] || "build/#{iteration_id(entry)}-#{lane}/wt")
        else
          repo = lanes.first&.dig("repo")
          raise Space::Core::Error, "No lane/repo recorded for '#{iteration}' — cannot resolve a directory to run gates in" unless repo
          space.path.join("repos", repo)
        end
      raise Space::Core::Error, "directory does not exist: #{base_dir}" unless base_dir.exist?

      execute_gates(gates, base_dir: base_dir, lane: lane, repo_root: repo_root)
    end

    # Rehearse the DRAFTED gates in the WORKING-TREE iteration file — before the
    # freeze, while they can still be fixed — through the identical execution
    # path #run_gates uses at judge time (#execute_gates). space.yaml records no
    # lanes until freeze! writes them (#freeze!, :~209), so the run directory is
    # resolved from the DRAFTED ```lanes``` block instead of the recorded one;
    # rehearsal always runs in the repo checkout (repos/<repo>), never a lane
    # worktree, because lane worktrees are not provisioned until after the
    # freeze. Classifies each result RED/GREEN/BROKEN (I09/AC5) and stamps the
    # iteration as rehearsed, keyed to the gates block's content (I09/AC7) — the
    # stamp records that the architect looked, never that gates passed.
    def rehearse(iteration, now: Time.now)
      entry = slice_entry(iteration)
      rel = entry["file"]
      path = space.path.join(rel)
      raise Space::Core::Error, "#{rel} does not exist — run `architect new #{iteration}` first" unless path.exist?
      text = path.read

      gates = parse_gates(text)
      repo, base_dir, gate_results, scope_report =
        if gates.empty?
          [nil, nil, [], nil]
        else
          r   = resolve_rehearsal_repo(iteration, text)
          dir = space.path.join("repos", r)
          raise Space::Core::Error, "directory does not exist: #{dir}" unless dir.exist?
          results = execute_gates(gates, base_dir: dir, lane: nil, repo_root: nil)
                    .map { |g| g.merge(rehearsal: classify_rehearsal(g)) }
          [r, dir, results, scope_asymmetry_report(gates, text, dir)]
        end

      digest = gates_digest(text)
      update_architect_block do |b|
        (b["iterations"] || []).each do |s|
          next unless s["name"] == iteration
          s["rehearsal"] = { "gates_digest" => digest, "at" => now.iso8601 }
        end
        b
      end

      { iteration: iteration, repo: repo, base_dir: base_dir, gates: gate_results,
        empty: gates.empty?, placeholder: untouched_ac_placeholder?(text), scope_asymmetry: scope_report }
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

      space.repos.each do |repo|
        name      = repo["name"]
        repo_path = space.path.join("repos", name).to_s
        next unless Dir.exist?(repo_path)

        branch_out, _, branch_st = git_capture("-C", repo_path, "symbolic-ref", "--short", "HEAD")
        next unless branch_st.success?
        branch = branch_out.strip

        git_capture("-C", repo_path, "fetch", "origin")

        count_out, _, count_st = git_capture("-C", repo_path, "rev-list", "--left-right", "--count",
          "#{branch}...origin/#{branch}")
        next unless count_st.success?

        behind = count_out.strip.split[1].to_i
        if behind > 0
          parts << "WARNING: repos/#{name} local #{branch} is #{behind} commits behind " \
            "origin/#{branch} — run `architect sync #{name}`"
        end
      rescue
        # tolerate fetch or comparison failures silently
      end

      parts.join("\n")
    end

    # Sync tracked repo clones with their remotes (fast-forward only).
    # Returns an array of result hashes: { repo:, status:, message: }.
    # With no repo_name, syncs every tracked repo; with a name, syncs only that one.
    def sync_repos(repo_name: nil)
      repos = space.repos
      if repo_name
        repos = repos.select { |r| r["name"] == repo_name }
        raise Space::Core::Error, "repo '#{repo_name}' not tracked in this space" if repos.empty?
      end
      repos.map { |r| sync_one_repo(r["name"]) }
    end

    def worktree_add(repo, iteration, lane, base: nil, harness: nil, model: nil, variant: false,
                     effort: nil, touch: nil, force: false, err: $stderr)
      model, suffix_level = Harness.parse_model_suffix(model)
      harness, model = resolve_harness_model(harness, model)
      resolved_level = effort || suffix_level || project_defaults["effort"]
      Harness.validate_thinking_level!(resolved_level)
      if effort.nil? && suffix_level
        err.puts "thinking: model suffix ':#{suffix_level}' parsed from lane model → level=#{suffix_level} (model stripped)"
      end

      entry = slice_entry(iteration)
      repo_path = space.path.join("repos", repo)
      raise Space::Core::Error, "repos/#{repo} does not exist" unless repo_path.exist?

      id = iteration_id(entry)
      wt_path   = space.path.join("build", "#{id}-#{lane}", "wt")
      FileUtils.mkdir_p(wt_path.dirname)

      base_ref = base || "HEAD"
      base_sha, _, wt_status = git_capture("-C", repo_path.to_s, "rev-parse", base_ref)
      raise Space::Core::Error, "Could not resolve base ref '#{base_ref}' in #{repo}" unless wt_status.success?
      base_sha = base_sha.strip

      branch = "lane/#{id}-#{lane}"

      # Guard: an existing directory that is not a registered worktree is ambiguous.
      if wt_path.exist? && !worktree_registered?(repo_path, wt_path)
        if force
          FileUtils.rm_rf(wt_path)
        else
          raise Space::Core::Error,
            "#{wt_path} exists but is not a registered git worktree of #{repo} — " \
            "resolve manually before re-running worktree_add, or re-run with --force to clear and re-create it"
        end
      end

      # Skip git worktree add when the branch and worktree already exist (idempotent re-run).
      unless branch_exists?(repo_path, branch) && worktree_registered?(repo_path, wt_path)
        if branch_exists?(repo_path, branch)
          # The worktree was removed but its lane branch survived — re-attach the branch
          # (carrying its own tip) instead of `-b`, which would fail "branch already exists".
          git_run("-C", repo_path.to_s, "worktree", "add", wt_path.to_s, branch)
        else
          git_run("-C", repo_path.to_s, "worktree", "add", wt_path.to_s, "-b", branch, base_sha)
        end
      end

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
      new_fields["effort"]    = resolved_level if resolved_level
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
      Space::Core::Paths.layout_children(wt_base).select(&:directory?).map { |p| p.basename.to_s }.sort
    end

    # Materialize the iteration's declared lanes: for each lane (or the one named via
    # `lane:`), create its worktree + lane/<id>-<lane> branch from the resolved base and
    # record worktree/base_sha/integration_branch. Idempotent — an already-materialized
    # lane is skipped, not re-created. Refuses until the iteration is frozen, because
    # declarations are not authoritative until then.
    def provision(iteration, base: nil, lane: nil, force: false)
      entry = slice_entry(iteration)
      raise Space::Core::Error,
        "Iteration '#{iteration}' is not frozen — freeze before provisioning (declarations are not authoritative until frozen)." \
        unless entry["freeze_sha"]

      lanes = entry["lanes"] || []
      lanes = lanes.select { |l| l["name"] == lane } if lane
      raise Space::Core::Error, "No lane '#{lane}' declared for iteration '#{iteration}'" if lane && lanes.empty?

      lanes.map do |l|
        name = l["name"]
        repo_path = space.path.join("repos", l["repo"])
        wt_path = space.path.join(l["worktree"] || "build/#{iteration_id(entry)}-#{name}/wt")
        if wt_path.exist? && worktree_registered?(repo_path, wt_path)
          { lane: name, worktree: wt_path, base_sha: l["base_sha"], created: false }
        else
          result = worktree_add(l["repo"], iteration, name, base: resolve_lane_base(l["repo"], base),
                                force: force, **recorded_lane_fields(l))
          { lane: name, worktree: result[:worktree], base_sha: result[:base_sha], created: true }
        end
      end
    end

    def verify(iteration, commit_mode: nil)
      entry = slice_entry(iteration)
      (entry["lanes"] || []).map do |lane|
        ensure_lane_materialized(iteration, lane["name"])
        { lane: lane["name"], repo: lane["repo"], checks: lane_mechanical_checks(entry, lane, commit_mode: commit_mode) }
      end
    end

    def dispatch(iteration, lane, model: nil, max_turns: 200,
                 claude_bin: nil, harness: nil, opencode_bin: nil, effort: nil, force: false, quiet: false,
                 detach: false, push_url: nil, push_token: nil, push_host: nil, run_creator: nil,
                 push_client: nil, timeout: nil, prompt: nil, now: Time.now)
      raise Space::Core::Error, "Specify --push-host or --push-url, not both" if push_host && push_url
      raise Space::Core::Error, "--push-host requires --push-token"           if push_host && !push_token
      raise Space::Core::Error, "--detach cannot be combined with --push-url or --push-host" \
        if detach && (push_url || push_host)

      err = quiet ? File.open(File::NULL, "w") : $stderr

      entry = slice_entry(iteration)
      lane_entry = (entry["lanes"] || []).find { |l| l["name"] == lane }
      raise Space::Core::Error, "No lane '#{lane}' recorded for iteration '#{iteration}'" unless lane_entry
      lane_entry = ensure_lane_materialized(iteration, lane)

      resolved_harness, resolved_model, resolved_effort =
        resolve_dispatch_harness(lane_entry, model: model, harness: harness, effort: effort, force: force, err: err)

      raise Space::Core::Error, "--push-host is only supported with the claude-code harness" \
        if push_host && resolved_harness != "claude-code"

      id = iteration_id(entry)
      wt_path = space.path.join(lane_entry["worktree"] || "build/#{id}-#{lane}/wt")
      raise Space::Core::Error, "Worktree directory does not exist: #{wt_path}" unless wt_path.exist?

      build_dir    = space.path.join("build", "#{id}-#{lane}")
      prompt_path  = build_dir.join("prompt.md")
      run_log_path = build_dir.join("run.jsonl")
      report_path  = build_dir.join("report.md")

      # --prompt: the caller authors the lane prompt anywhere (a fresh scratch file)
      # and the CLI owns the canonical copy — byte-for-byte, like variant_add.
      copy_and_validate_prompt!(prompt, prompt_path)

      bin = resolved_harness == "claude-code" ? claude_bin : opencode_bin
      harness_obj = Harness.for(resolved_harness, model: resolved_model, max_turns: max_turns, bin: bin,
                                                  config_dir: build_dir, effort: resolved_effort, force: force, err: err)

      # Stamp launch time and the resolved harness/model/effort onto the lane entry:
      # after every preflight validation has passed (a dispatch that raises above
      # records nothing) and before the blocking run or a detached dispatch returns.
      # A re-dispatch overwrites the prior values, so `architect status` always reads
      # what actually ran on the last dispatch.
      update_architect_block do |b|
        (b["iterations"] || []).each do |s|
          next unless s["name"] == iteration
          (s["lanes"] || []).each do |l|
            next unless l["name"] == lane
            l["dispatched_at"] = now.iso8601
            l["harness"]       = resolved_harness
            l["model"]         = resolved_model
            l["effort"]        = resolved_effort if resolved_effort
          end
        end
        b
      end

      if detach
        pid = harness_obj.run_detached(
          prompt_path:  prompt_path,
          run_log_path: run_log_path,
          chdir:        wt_path
        )
        result = { pid: pid, run_log: run_log_path, report: report_path, worktree: wt_path }
        result[:prompt_copied] = prompt_path if prompt
        result
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
          run_kwargs[:err]         = err         if quiet
        end
        exit_code = harness_obj.run(**run_kwargs)

        result = { exit_code: exit_code, run_log: run_log_path, report: report_path, worktree: wt_path }
        result[:prompt_copied]  = prompt_path    if prompt
        result[:timed_out]      = true           if exit_code == Harness::ClaudeCodeHarness::TIMEOUT_EXIT_CODE
        result[:created_run_id] = created_run_id if created_run_id
        result[:push_url]       = push_url       if push_url
        result
      end
    end

    # Submit the lane's builder run as a job to the space-server's queue instead of
    # running it locally: the sandboxed executor mounts the lane worktree + the repo
    # checkout at their identical host absolute paths (so the worktree's gitdir
    # pointer resolves) and runs the harness itself — no local run.jsonl, the
    # transcript lives server-side. jobs_client: is the injectable seam (mirrors
    # dispatch's run_creator:).
    def dispatch_as_job(iteration, lane, host:, token:, backend_url:, model: nil, harness: nil,
                        max_turns: 200, effort: nil, force: false, quiet: false,
                        job_model: nil, api_key_ref: nil, prompt: nil, jobs_client: nil, now: Time.now)
      err = quiet ? File.open(File::NULL, "w") : $stderr

      entry = slice_entry(iteration)
      lane_entry = (entry["lanes"] || []).find { |l| l["name"] == lane }
      raise Space::Core::Error, "No lane '#{lane}' recorded for iteration '#{iteration}'" unless lane_entry
      lane_entry = ensure_lane_materialized(iteration, lane)

      resolved_harness, resolved_model, resolved_effort =
        resolve_dispatch_harness(lane_entry, model: model, harness: harness, effort: effort, force: force, err: err)
      raise Space::Core::Error, "--as-job only supports the claude-code harness (lane '#{lane}' resolves to '#{resolved_harness}')" \
        unless resolved_harness == "claude-code"
      raise Space::Core::Error, "--job-model is required with --as-job" unless job_model

      id = iteration_id(entry)
      wt_path = space.path.join(lane_entry["worktree"] || "build/#{id}-#{lane}/wt")
      raise Space::Core::Error, "Worktree directory does not exist: #{wt_path}" unless wt_path.exist?

      build_dir   = space.path.join("build", "#{id}-#{lane}")
      prompt_path = build_dir.join("prompt.md")
      copy_and_validate_prompt!(prompt, prompt_path)

      repo_path   = space.path.join("repos", lane_entry["repo"])
      harness_obj = Harness.for(resolved_harness, model: resolved_model, max_turns: max_turns,
                                                  effort: resolved_effort, force: force, err: err)

      spec = job_spec(iteration: iteration, lane: lane, wt_path: wt_path, build_dir: build_dir,
        repo_path: repo_path, prompt_content: prompt_path.read, backend_url: backend_url,
        job_model: job_model, api_key_ref: api_key_ref, harness_args: harness_obj.builder_args)

      client = jobs_client || JobsClient.new(host, token)
      job_id = client.create(spec)

      # Dispatch bookkeeping, mirroring the local path's dispatched_at stamp: a
      # re-dispatch overwrites the prior job_id, so `architect status` always
      # reflects the last dispatch regardless of mode.
      update_architect_block do |b|
        (b["iterations"] || []).each do |s|
          next unless s["name"] == iteration
          (s["lanes"] || []).each do |l|
            next unless l["name"] == lane
            l["dispatched_at"] = now.iso8601
            l["job_id"]        = job_id
          end
        end
        b
      end

      result = { job_id: job_id, spec: spec }
      result[:prompt_copied] = prompt_path if prompt
      result
    end

    private

    attr_reader :space

    # Compose a commit message. Without a custom message, the canonical default
    # (unchanged). With one, a short canonical prefix keeps the loop's commit
    # taxonomy grep-able while the author's first line owns the subject; any
    # remaining lines become the commit body — the space's git log is the loop's
    # durable memory, so callers are encouraged to write detailed bodies.
    def compose_message(prefix, default, message)
      return default if message.nil? || message.strip.empty?

      subject, _, body = message.strip.partition("\n")
      composed = "#{prefix} #{subject.strip}"
      body = body.strip
      body.empty? ? composed : "#{composed}\n\n#{body}"
    end

    # Remove each lane's worktree and safe-delete (`-d`) its lane branch. Accepts
    # either merge_lane! results (symbol keys) or recorded lane entries (string
    # keys) — both carry a lane name and a repo.
    def teardown_lanes!(iteration, lane_entries)
      id = iteration_id(slice_entry(iteration))
      lane_entries.map do |l|
        lane = l[:lane] || l["name"]
        repo = l[:repo] || l["repo"]
        worktree_remove(iteration, lane)
        lane_branch = "lane/#{id}-#{lane}"
        git_capture("-C", space.path.join("repos", repo).to_s, "branch", "-d", lane_branch)
        { lane: lane, repo: repo, lane_branch: lane_branch }
      end
    end

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

      # paths:exempt - the /\AI\d+-.+\.md\z/ filter structurally cannot match a dotfile-prefixed name, so raw enumeration is already dotfile-safe here
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
      pid   = Process.spawn("/bin/sh", "-c", cmd, pgroup: true, chdir: dir.to_s, out: out_f.path, err: err_f.path)

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

    # HOW gates execute — the one instrument #run_gates (judge time) and
    # #rehearse (pre-freeze) both call, byte-for-byte: same cwd-remap semantics,
    # same shell (capture_with_timeout's Process.spawn), same GateEvaluator,
    # same timeout handling (I09/AC3). repo_root/lane are nil outside a lane
    # context (rehearsal never has one — it always runs in the repo checkout).
    def execute_gates(gates, base_dir:, lane:, repo_root:)
      gates.map do |gate|
        g   = gate.transform_keys(&:to_s)
        dir =
          if (cwd = g["cwd"])
            gate_cwd = space.path.join(cwd)
            if lane && repo_root && (gate_cwd == repo_root || gate_cwd.to_s.start_with?("#{repo_root}/"))
              base_dir.join(gate_cwd.relative_path_from(repo_root)).cleanpath
            else
              gate_cwd
            end
          else
            base_dir
          end
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
          dir: dir, status: status, reason: reason, timed_out: captured[:timed_out] }
      end
    end

    # I09/AC4: resolve rehearsal's run repo from the DRAFTED ```lanes``` block —
    # one repo, unambiguously declared or inferable, else a message naming what
    # to do. Never from space.yaml (no lanes are recorded there pre-freeze).
    def resolve_rehearsal_repo(iteration, text)
      declared = parse_lanes(text).filter_map { |l| l["repo"] }.uniq
      return declared.first if declared.size == 1

      if declared.empty?
        tracked = space.repos.map { |r| r["name"] }
        return tracked.first if tracked.size == 1
        raise Space::Core::Error,
          "Cannot resolve a repo to rehearse '#{iteration}' against — no lane declares a repo and the space " \
          "tracks #{tracked.size} repos (#{tracked.join(', ')}). Declare a ```lanes``` block in the " \
          "Specification, naming the repo to rehearse against."
      end

      raise Space::Core::Error,
        "Cannot resolve a single repo to rehearse '#{iteration}' against — the drafted lanes block names " \
        "multiple repos (#{declared.join(', ')}). Rehearsal runs once, against one repo checkout; narrow the " \
        "```lanes``` block before rehearsing."
    end

    # I09/AC5: RED (clean non-zero — discriminates) vs GREEN (passes on base) vs
    # BROKEN (127, timeout, or a shell parse failure). BROKEN is advisory, not
    # authoritative: a correct RED can look broken (e.g. `grep -q x new_file`
    # exits 2 — "No such file" — when the file is one the lane will write); the
    # CLI names this suspicion, the architect confirms it.
    def classify_rehearsal(result)
      return :broken if result[:timed_out] || result[:exit_code] == 127
      return :broken if BROKEN_STDERR_PATTERN.match?(result[:stderr].to_s)
      result[:status] == :pass ? :green : :red
    end

    # I12/AC3: rehearse's scope-asymmetry check. I11 shipped a bug its own new
    # boundary discipline could not catch: a gate's grep-family search covered
    # only `lib`, while the identifier it renamed also lived in a `test/` file
    # no lane declared — three consistent statements, all drawn from the same
    # too-narrow grep. For each gate whose command is a recognizable
    # file-scoped grep invocation, re-run its own pattern across the whole repo
    # and report anything that matches outside the gate's own declared paths,
    # flagging loudest whatever also lies outside every declared lane's touch
    # set (I12/AC4) — the file no lane may legally fix. touch_globs is that
    # union; parse_lanes returns [] with no ```lanes``` block, which still
    # yields the outside-every-lane half of the report. Reports only: never
    # touches rehearse's exit code, RED/GREEN/BROKEN, or the rehearsal stamp.
    SCOPE_GREP_BINARIES = %w[grep egrep fgrep].freeze

    # Shellwords treats shell syntax — pipes, `&&`/`||`/`;`, `$(...)`, control
    # keywords — as ordinary word characters, not structure (its own docs say
    # plainly this isn't a command-line parser). These are the markers
    # #shell_segments splits a token stream on, once #pad_shell_operators has
    # made sure none of them can arrive glued to an adjacent word.
    SCOPE_BOUNDARY_TOKENS = %w[| || && ; $( ( ) if elif then else fi do done while until case esac].freeze

    # Flags that change what a pattern matches — safe to replay verbatim
    # against the real grep binary, never reinterpreted in Ruby — vs flags
    # that only change what's printed (irrelevant to a files-with-matches
    # re-run).
    SCOPE_MATCH_FLAGS = %w[E F G P w x].freeze
    SCOPE_NOOP_FLAGS = %w[c i n o q r l z H h].freeze

    # git grep, not a raw recursive grep: it skips .git's own object store (a
    # raw `grep -r .` would trawl it) and matches "the tree" the way the rest
    # of this corpus's git-based gates already do (diff-scope's own gates are
    # git diff, not find/grep). Small fixed budget — runs once per recognized
    # invocation, not per gate.
    SCOPE_SEARCH_TIMEOUT = 30

    def scope_asymmetry_report(gates, text, base_dir)
      touch_globs = parse_lanes(text).flat_map { |l| l["touch"] || [] }
      findings = []
      not_analyzable = []

      gates.each do |gate|
        g = gate.transform_keys(&:to_s)
        grep_invocations(g["cmd"].to_s).each do |inv|
          if inv[:status] != :recognized
            not_analyzable << { id: g["id"], reason: inv[:reason] }
            next
          end

          finding = scope_finding(inv, base_dir, touch_globs)
          if finding
            findings << finding.merge(id: g["id"])
          else
            not_analyzable << { id: g["id"], reason: "whole-repo re-run failed" }
          end
        end
      end

      { findings: findings, not_analyzable: not_analyzable }
    end

    # Re-runs a recognized invocation's own pattern across the whole repo and
    # splits what it finds into: the gate's own declared scope (expected —
    # that's what the gate already searches, so it's not reported), elsewhere
    # but inside some lane's touch set, and elsewhere outside every lane's
    # touch set. nil signals the re-run itself failed (caller counts it as
    # not-analyzable rather than reporting a guess).
    def scope_finding(inv, base_dir, touch_globs)
      matched = whole_repo_grep_matches(inv, base_dir)
      return nil unless matched

      elsewhere = matched.reject { |f| within_declared_scope?(f, inv[:paths], base_dir) }
      outside_lanes, within_lanes = elsewhere.partition { |f| !in_touch_set?(f, touch_globs) }
      { pattern: inv[:pattern], paths: inv[:paths], outside_lanes: outside_lanes.sort, within_lanes: within_lanes.sort }
    end

    # The files (relative paths) an invocation's own pattern matches anywhere
    # in the repo, via the real git-grep binary with the same
    # matching-relevant flags — never a Ruby reimplementation of grep's
    # pattern semantics. nil on anything other than a clean "matched"/"no
    # matches" outcome (exit 0/1); [] is a real, examined zero.
    def whole_repo_grep_matches(inv, base_dir)
      flags = ["-l", "-I"]
      flags << "-i" if inv[:case_insensitive]
      flags << "-#{inv[:mode]}" unless inv[:mode] == "G"
      cmd = "git grep #{flags.join(' ')} -- #{Shellwords.escape(inv[:pattern])}"
      captured = capture_with_timeout(cmd, dir: base_dir, timeout: SCOPE_SEARCH_TIMEOUT)
      return [] if captured[:exit_code] == 1
      return nil if captured[:timed_out] || captured[:exit_code] != 0

      captured[:stdout].each_line.map(&:chomp).reject(&:empty?)
    end

    # Is relative_path inside one of an invocation's own declared search
    # paths? A declared path that's a real directory at rehearsal time covers
    # anything under it; a file (or a path a lane hasn't written yet, same
    # BROKEN-adjacent case #classify_rehearsal already names) covers only
    # itself.
    def within_declared_scope?(relative_path, declared_paths, base_dir)
      declared_paths.any? do |p|
        p = p.sub(%r{/\z}, "")
        relative_path == p || (base_dir.join(p).directory? && relative_path.start_with?("#{p}/"))
      end
    end

    # Every grep-family invocation recognized in one gate's shell command. A
    # command that never mentions grep/egrep/fgrep isn't this check's concern
    # at all (silently absent, same as e.g. `bundle exec rake test`) — only a
    # command that DOES attempt one and can't be cleanly recognized is
    # reported not-analyzable (I12/AC4's "counted and identifiable").
    def grep_invocations(cmd)
      return [] unless cmd.match?(/\b(?:#{SCOPE_GREP_BINARIES.join('|')})\b/)

      segments = shell_segments(cmd)
      return [{ status: :not_analyzable, reason: "unparseable command" }] unless segments

      found = segments.filter_map { |seg| grep_invocation(seg) }
      return [{ status: :not_analyzable, reason: "could not locate a recognizable grep invocation" }] if found.empty?

      found
    end

    # Splits a gate's shell command into simple-command segments at pipes,
    # `&&`/`||`/`;`, command substitution, and control keywords (see
    # SCOPE_BOUNDARY_TOKENS). Returns nil on anything Shellwords itself can't
    # tokenize (an unmatched quote), so the caller counts it instead of
    # guessing at it.
    def shell_segments(cmd)
      tokens = expand_quoted_substitutions(shell_tokenize(cmd))
      segments = [[]]
      tokens.each do |tok|
        if SCOPE_BOUNDARY_TOKENS.include?(tok)
          segments << []
        else
          segments.last << tok
        end
      end
      segments.reject(&:empty?)
    rescue ArgumentError
      nil
    end

    def shell_tokenize(cmd)
      Shellwords.split(pad_shell_operators(cmd))
    end

    # Shellwords treats shell operator/substitution punctuation as ordinary
    # word characters whenever it isn't whitespace-separated (its own docs
    # warn this isn't a command-line parser) — pads whitespace around
    # `$(` `&&` `||` `;` `|` `(` `)` and folds a bare newline to `;` (its own
    # statement terminator, otherwise invisible to Shellwords as anything but
    # whitespace) so each always surfaces as its own token. Quoted spans and
    # backslash-escapes are passed through untouched, so a pattern's own `|`
    # or `$` — inside a quote — is never mistaken for shell syntax.
    def pad_shell_operators(text)
      out = String.new
      text.scan(/'[^']*'|"(?:[^"\\]|\\.)*"|\\.|[^'"\\]+/m) do |chunk|
        if chunk.start_with?("'", '"', "\\")
          out << chunk
        else
          out << chunk.gsub(/\$\(|&&|\|\||[();|\n]/) { |op| op == "\n" ? " ; " : " #{op} " }
        end
      end
      out
    end

    # A token that is ITSELF a whole `$(...)` survives #pad_shell_operators
    # intact only when the substitution sat inside a still-open quote
    # (protected, so nothing inside it got space-padded) — recurse into its
    # contents exactly as the top-level command was tokenized.
    def expand_quoted_substitutions(tokens)
      tokens.flat_map do |tok|
        m = tok.match(/\A\$\((.*)\)\z/m)
        next [tok] unless m

        ["$("] + expand_quoted_substitutions(shell_tokenize(m[1])) + [")"]
      end
    end

    # Recognizes one simple-command segment as a file-scoped grep-family
    # invocation, or declines with a specific reason. Never guesses: `-v`
    # inverts per-line matching (fine for filtering a computed list, wrong for
    # "does this pattern occur elsewhere") so it's declined rather than
    # silently reinterpreted; so is any unsupported flag or a path operand
    # that still carries an unresolved shell variable.
    def grep_invocation(segment)
      i = 0
      i += 1 while segment[i] == "!"
      return nil unless segment[i] && SCOPE_GREP_BINARIES.include?(segment[i])
      i += 1

      flag_chars = []
      loop do
        tok = segment[i]
        break unless tok
        if tok == "--"
          i += 1
          break
        elsif tok.start_with?("-") && tok != "-"
          flag_chars.concat(tok.delete_prefix("-").chars)
          i += 1
        else
          break
        end
      end

      unsupported = flag_chars - (SCOPE_MATCH_FLAGS + SCOPE_NOOP_FLAGS)
      return { status: :not_analyzable, reason: "unsupported flag(s): #{unsupported.uniq.join(', ')}" } if unsupported.any?
      return { status: :not_analyzable, reason: "-v (inverted match) semantics not safely reinterpreted" } if flag_chars.include?("v")

      modes = (flag_chars & %w[E F G P]).uniq
      return { status: :not_analyzable, reason: "ambiguous pattern flags: #{modes.join(', ')}" } if modes.size > 1
      return { status: :not_analyzable, reason: "no pattern operand" } unless segment[i]

      pattern = segment[i]
      paths = segment[(i + 1)..] || []
      return { status: :not_analyzable, reason: "no path operand (pipeline/stdin search)" } if paths.empty?
      return { status: :not_analyzable, reason: "path operand contains an unresolved shell variable" } if paths.any? { |p| p.include?("$") }

      { status: :recognized, pattern: pattern, paths: paths,
        case_insensitive: flag_chars.include?("i"), mode: modes.first || "G" }
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

    # Materialize a declared lane on demand: when its worktree is absent, create it
    # identically to `provision` (same base resolution, same worktree_add primitive)
    # so no dispatch/integrate/gate path dead-ends on a missing worktree. Returns the
    # (possibly refreshed) lane entry; a no-op when already materialized or undeclared.
    def ensure_lane_materialized(iteration, lane)
      entry = slice_entry(iteration)
      lane_entry = (entry["lanes"] || []).find { |l| l["name"] == lane }
      return lane_entry unless lane_entry && lane_entry["repo"]

      repo_path = space.path.join("repos", lane_entry["repo"])
      return lane_entry unless repo_path.exist?
      wt_path = space.path.join(lane_entry["worktree"] || "build/#{iteration_id(entry)}-#{lane}/wt")
      return lane_entry if wt_path.exist? && worktree_registered?(repo_path, wt_path)

      worktree_add(lane_entry["repo"], iteration, lane, base: resolve_lane_base(lane_entry["repo"], nil),
                   **recorded_lane_fields(lane_entry))
      (slice_entry(iteration)["lanes"] || []).find { |l| l["name"] == lane }
    end

    # The lane's declared harness/model/variant/effort, as worktree_add kwargs — so a
    # re-materialize preserves them instead of merging back to defaults. touch_set is
    # deliberately omitted: worktree_add leaves it untouched, so it already survives.
    # The space.yaml project block's optional harness/model/effort defaults (empty
    # hash when the block or the keys are absent).
    def project_defaults
      space.data["project"] || {}
    end

    # Resolve harness + model by precedence: explicit value > (dispatch only) the
    # lane's stored value > space.yaml project.harness/project.model > the
    # per-harness sensible default (model only, keyed on the resolved harness).
    # Shared by worktree_add and dispatch so both read the same defaults. A stored
    # model is only honored when its stored harness still matches the resolved
    # harness — a dispatch-time harness override drops the old harness's stored
    # model instead of leaking it into the new harness's run.
    def resolve_harness_model(harness, model, stored_harness: nil, stored_model: nil)
      defaults = project_defaults
      resolved_harness = (harness || stored_harness || defaults["harness"] || "claude-code").to_s
      stored_model = nil unless stored_harness.nil? || stored_harness.to_s == resolved_harness
      resolved_model = model || stored_model || defaults["model"] || Harness.default_model_for(resolved_harness)
      [resolved_harness, resolved_model]
    end

    # --prompt: the caller authors the lane prompt anywhere (a fresh scratch file) and
    # the CLI owns the canonical copy — byte-for-byte, like variant_add. Shared by
    # dispatch and dispatch_as_job so both refuse the same empty/stub prompt.
    def copy_and_validate_prompt!(prompt, prompt_path)
      if prompt
        src = Pathname.new(prompt)
        raise Space::Core::Error, "prompt file not found: #{src}" unless src.exist?
        File.open(prompt_path, "wb") { |f| f.write(File.binread(src)) }
      end

      raise Space::Core::Error, "prompt.md not found: #{prompt_path}" unless prompt_path.exist?

      prompt_content = prompt_path.read.strip
      raise Space::Core::Error, "Write this lane's prompt to #{prompt_path} before dispatching." \
        if prompt_content.empty? || prompt_content == PROMPT_STUB.strip
    end

    # Resolve harness/model/effort for a dispatch (local or --as-job), shared so the
    # two dispatch paths can never drift on precedence or thinking-level translation.
    def resolve_dispatch_harness(lane_entry, model:, harness:, effort:, force:, err:)
      model, suffix_level = Harness.parse_model_suffix(model)
      resolved_harness, resolved_model = resolve_harness_model(harness, model,
        stored_harness: lane_entry["harness"], stored_model: lane_entry["model"])

      resolved_effort =
        if effort
          Harness.validate_thinking_level!(effort) unless force
          effort
        elsif suffix_level
          err.puts "thinking: model suffix ':#{suffix_level}' parsed from --model → level=#{suffix_level} (model stripped to '#{model}')"
          suffix_level
        else
          lane_entry["effort"]
        end

      [resolved_harness, resolved_model, resolved_effort]
    end

    # Compose a dispatch --as-job spec per the space-server's job contract: prompt +
    # workspace.dir (the lane worktree) + environment (deps/network/mounts/env or
    # secrets) + harness (claude/backend/args) + provenance. mounts are src:dst with
    # src == dst — the sandboxed executor requires the lane worktree AND the repo
    # checkout mounted at their identical host absolute paths for the worktree's
    # gitdir pointer to resolve.
    def job_spec(iteration:, lane:, wt_path:, build_dir:, repo_path:, prompt_content:, backend_url:,
                job_model:, api_key_ref:, harness_args:)
      harness = { "type" => "claude", "backend" => { "base_url" => backend_url }, "args" => harness_args }
      harness["model"] = job_model if job_model
      harness["backend"]["api_key_ref"] = api_key_ref if api_key_ref

      environment = {
        "env"  => api_key_ref ? {} : { "ANTHROPIC_API_KEY" => "unused-for-keyless-backends" },
        "deps" => ["git"],
        "permissions" => {
          "network" => true,
          "mounts"  => ["#{build_dir}:#{build_dir}", "#{repo_path}:#{repo_path}"]
        }
      }
      environment["secrets"] = [{ "ref" => api_key_ref, "name" => "ANTHROPIC_API_KEY" }] if api_key_ref

      {
        "prompt"      => prompt_content,
        "workspace"   => { "dir" => wt_path.to_s },
        "environment" => environment,
        "harness"     => harness,
        "provenance"  => { "space" => Space::Core::Slugger.slug(space.title), "iteration" => iteration, "lane" => lane }
      }
    end

    def recorded_lane_fields(lane_entry)
      {
        harness: lane_entry["harness"] || "claude-code",
        model:   lane_entry["model"],
        variant: lane_entry["variant"] || false,
        effort:  lane_entry["effort"]
      }
    end

    # Resolve the base ref a lane's worktree branches from: an explicit override wins;
    # otherwise the project/<slug> integration branch when it exists, else the repo's
    # default branch.
    def resolve_lane_base(repo, override)
      return override if override
      repo_path = space.path.join("repos", repo)
      integration = project_integration_branch
      return integration if branch_exists?(repo_path, integration)
      repo_default_branch(repo_path)
    end

    def repo_default_branch(repo_path)
      out, _, st = git_capture("-C", repo_path.to_s, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
      return out.strip.sub(%r{\Aorigin/}, "") if st.success? && !out.strip.empty?
      out, _, st = git_capture("-C", repo_path.to_s, "symbolic-ref", "--short", "HEAD")
      st.success? && !out.strip.empty? ? out.strip : "HEAD"
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
    def lane_mechanical_checks(entry, lane, commit_mode: nil)
      freeze_sha = entry["freeze_sha"]
      rel = entry["file"]
      lane_name = lane["name"]
      base_sha = lane["base_sha"]
      wt_path = space.path.join(lane["worktree"] || "build/#{iteration_id(entry)}-#{lane_name}/wt")
      touch_set = lane["touch_set"] || []

      checks = {}

      # (a) frozen sections of the iteration file untouched since freeze
      checks[:frozen_untouched] = (!frozen_region_changed?(freeze_sha, rel) if freeze_sha && rel)

      # (b) no builder commits in the worktree (the architect's integrate commit is excluded;
      #     in conductor mode, canonical conductor commits are also excluded)
      effective_commit_mode = commit_mode || space.data.dig("project", "commit_mode") || "strict"
      log_out, = git_capture("-C", wt_path.to_s, "log", "--format=%H%x09%s", "#{base_sha}..")
      commit_entries = log_out.strip.split("\n").filter_map do |line|
        sha, subject = line.strip.split("\t", 2)
        { sha: sha, subject: subject.to_s } unless sha.nil? || sha.empty?
      end
      recorded_integrate = lane["integrate_sha"]&.strip
      canonical_conductor = "#{iteration_id(entry)}-#{lane_name}: builder output"
      builder_commits = commit_entries.reject do |c|
        c[:sha] == recorded_integrate ||
          (effective_commit_mode == "conductor" && c[:subject] == canonical_conductor)
      end
      checks[:no_builder_commits] = builder_commits.empty?

      # (c) builder's scratch report exists and is non-empty
      report = space.path.join("build", "#{iteration_id(entry)}-#{lane_name}", "report.md")
      checks[:report_exists] = report.exist? && !report.read.strip.empty?

      # (d) in-bounds: changed paths ⊆ touch_set (:no_touch_set if none recorded)
      checks[:in_bounds] = if touch_set.empty?
        :no_touch_set
      else
        # -z: NUL-delimited; renames emit new_path NUL old_path — include both
        status_out, = git_capture("-C", wt_path.to_s, "status", "--porcelain", "-z", "-uall")
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
        changed.all? { |f| in_touch_set?(f, touch_set) }
      end

      checks
    end

    # Is a changed path inside a lane's declared touch set? Single-sourced so the
    # in-bounds check (d) and merge_lane!'s conflict classification can never drift.
    def in_touch_set?(path, globs)
      globs.any? { |g| Space::Core::Paths.touch_match?(g, path) }
    end

    # Merge a lane's verbatim block into the current "## Builder Report" body for
    # #transcribe_evidence!: replace its own "### <lane>" subsection in place if
    # present (preserving the order lanes were already transcribed in), else append
    # a new one after the others. Subsection boundaries are matched against the
    # iteration's declared lane names (like KNOWN_HEADINGS for top-level sections),
    # not any "### " line, so a verbatim report containing its own "### " heading
    # can't fool the parser.
    def replace_lane_report(body, lane, raw, lane_names)
      block = "### #{lane}\n\n#{raw}"
      return block if placeholder_body?(body)

      headings = lane_names.map { |n| "### #{n}" }
      lines = body.lines
      start = lines.index { |l| l.chomp == "### #{lane}" }
      return "#{body.strip}\n\n#{block}" unless start

      finish = ((start + 1)...lines.length).find { |i| headings.include?(lines[i].chomp) } || lines.length
      before = lines[0...start].join.strip
      after = lines[finish..].join.strip
      [before, block, after].reject(&:empty?).join("\n\n")
    end

    # Replace (or, with append:, extend) the body of a "## Heading" section, leaving
    # every other section byte-untouched. Append replaces a placeholder body (only a
    # template comment) the first time, then stacks subsections after it. A supplied
    # block that redundantly repeats the section's own heading as its first line (the
    # natural way to author a complete section) has that leading line stripped first,
    # so writing the same section twice never accumulates a duplicate heading.
    def replace_section_body(text, heading, new_block, append:)
      lines = text.lines
      start = lines.index { |l| l.chomp == heading }
      raise Space::Core::Error, "section heading '#{heading}' not found in iteration file" unless start

      finish = ((start + 1)...lines.length).find { |i| KNOWN_HEADINGS.include?(lines[i].chomp) } || lines.length
      body = lines[(start + 1)...finish].join

      first, rest = new_block.strip.split("\n", 2)
      block = first == heading ? rest.to_s.strip : new_block.strip

      new_body =
        if append && !placeholder_body?(body)
          "#{body.strip}\n\n#{block}"
        else
          block
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

    # The raw (unparsed) text inside the fenced ```gates block, or nil when the
    # block itself is absent. Single-sourced so #parse_gates and the rehearsal
    # stamp's content digest (#gates_digest) can never read two different
    # slices of the same section.
    def gates_block_source(text)
      body = section_body(text, "## Acceptance Criteria")
      return nil unless body
      match = body.match(/^```gates\n(.*?)^```/m)
      match && match[1]
    end

    # Extract and parse the fenced ```gates block from the Acceptance Criteria section.
    # Returns an array of gate hashes (string-keyed). Returns [] when the block is
    # absent, empty, or contains only YAML comments.
    def parse_gates(text)
      raw = gates_block_source(text)
      return [] unless raw
      parsed = YAML.safe_load(raw, aliases: false)
      parsed.is_a?(Array) ? parsed : []
    end

    # A stable digest of the gates block's raw content — the key the I09/AC7
    # rehearsal stamp is validated against. Any byte edit to the fenced block
    # (add, remove, reorder, reword) changes this and invalidates the stamp.
    def gates_digest(text)
      Digest::SHA256.hexdigest(gates_block_source(text).to_s)
    end

    # #73, narrowly (I09/AC8): true only when the AC section still carries the
    # scaffold's untouched placeholder AND there is no active gate — a
    # hand-authored prose-only AC (placeholder replaced, still no gates) is not
    # this. Call only after lint_gates! has validated the block parses cleanly.
    def untouched_ac_placeholder?(text)
      body = section_body(text, "## Acceptance Criteria")
      return false unless body
      body.include?(AC1_PLACEHOLDER) && parse_gates(text).empty?
    end

    # I09/AC7: freeze! refuses without a fresh rehearsal stamp — one whose
    # gates_digest matches the CURRENT (about-to-be-frozen) gates block. Stale
    # (gates edited since) or absent (never rehearsed) both refuse identically;
    # the stamp records that the architect looked, never that gates passed.
    def ensure_rehearsed!(iteration, entry, text)
      stamp = entry["rehearsal"]
      return if stamp && stamp["gates_digest"] == gates_digest(text)

      raise Space::Core::Error,
        "Iteration '#{iteration}' has not been rehearsed against its current gates — " \
        "run `architect rehearse #{iteration}` first, or `architect freeze #{iteration} " \
        "--skip-rehearse REASON` to skip deliberately."
    end

    # Extract and parse the fenced ```lanes block from the Specification section.
    # Returns an array of lane declaration hashes (string-keyed). Returns [] when the
    # block is absent, empty, or contains only YAML comments (back-compat).
    def parse_lanes(text)
      body = section_body(text, "## Specification")
      return [] unless body
      match = body.match(/^```lanes\n(.*?)^```/m)
      return [] unless match
      parsed = YAML.safe_load(match[1], aliases: false)
      parsed.is_a?(Array) ? parsed : []
    end

    # Lint the lanes block in the given iteration file text. Raises Space::Core::Error
    # with aggregated messages on failure. An absent/empty block is allowed (back-compat).
    def lint_lanes!(text)
      lanes = begin
        parse_lanes(text)
      rescue Psych::SyntaxError => e
        raise Space::Core::Error, "ill-formed lanes block: #{e.message}"
      end
      return if lanes.empty?

      errors = lanes.each_with_index.flat_map do |l, i|
        unless l.is_a?(Hash)
          next ["lane #{i}: expected a mapping with name/repo/touch"]
        end
        touch = l["touch"]
        [
          ("lane #{i}: missing 'name'" if l["name"].to_s.strip.empty?),
          ("lane #{i}: missing 'repo'" if l["repo"].to_s.strip.empty?),
          ("lane #{i} (#{l["name"]}): 'touch' must be a non-empty array of globs" \
            unless touch.is_a?(Array) && touch.any? && touch.all? { |g| g.is_a?(String) && !g.strip.empty? })
        ].compact
      end
      return if errors.empty?
      raise Space::Core::Error, "ill-formed lanes block:\n#{errors.join("\n")}"
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
      raise Space::Core::Error, "ill-formed gates block:\n#{result.failure.join("\n")}" unless result.success?

      warn_bare_repo_prefix!(gates, warnings) if warnings
    end

    # I09/AC9(b), #39: a gate whose `cmd` carries a literal `repos/<name>/` prefix
    # with no `cwd` set is warned about, not failed — `cmd` already resolves
    # against the repo tree (`cwd` is what's space-root-relative), so this
    # pattern is usually a leftover space-root-relative path, but is legal and
    # occasionally correct. Threaded through the same warnings: channel
    # lint_gates! already carries, never a second channel.
    def warn_bare_repo_prefix!(gates, warnings)
      gates.each do |g|
        g = g.transform_keys(&:to_s)
        next if g["cwd"]
        next unless g["cmd"].to_s.match?(BARE_REPO_PREFIX)
        warnings << "gate '#{g["id"]}': cmd contains a literal 'repos/<name>/' path with no cwd set — " \
          "cmd already resolves against the repo tree, so this is likely a leftover space-root-relative " \
          "path (legal, occasionally correct — verify it)"
      end
    end

    # Raises if any lane in the entry has been dispatched (dispatched_at or integrate_sha set).
    # Used by freeze! and write_section! --force to prevent rewriting frozen content after a
    # builder has run (moving freeze_sha post-dispatch breaks the AC cardinal invariant).
    def dispatched_guard!(entry)
      lane = (entry["lanes"] || []).find { |l| l["dispatched_at"] || l["integrate_sha"] }
      return unless lane
      raise Space::Core::Error,
        "Lane '#{lane["name"]}' is already dispatched — cannot re-freeze or write frozen sections " \
        "after dispatch (a builder has run against the frozen AC; rewriting it breaks the cardinal invariant)."
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

    def sync_one_repo(name)
      repo_path = space.path.join("repos", name).to_s

      dirty_out, _, _ = git_capture("-C", repo_path, "status", "--porcelain")
      return { repo: name, status: :dirty, message: "#{name}: dirty working tree — skipping" } if dirty_out.strip.length > 0

      branch_out, _, branch_st = git_capture("-C", repo_path, "symbolic-ref", "--short", "HEAD")
      unless branch_st.success?
        return { repo: name, status: :error, message: "#{name}: detached HEAD — skipping" }
      end
      branch = branch_out.strip

      _, fetch_err, fetch_st = git_capture("-C", repo_path, "fetch", "origin")
      unless fetch_st.success?
        return { repo: name, status: :error, message: "#{name}: fetch failed — #{fetch_err.strip}" }
      end

      count_out, _, count_st = git_capture("-C", repo_path, "rev-list", "--left-right", "--count",
        "#{branch}...origin/#{branch}")
      unless count_st.success?
        return { repo: name, status: :error, message: "#{name}: could not compare with origin/#{branch}" }
      end

      ahead, behind = count_out.strip.split.map(&:to_i)
      return { repo: name, status: :up_to_date, message: "#{name}: up to date" } if behind == 0

      if ahead > 0
        return { repo: name, status: :diverged,
          message: "#{name}: behind #{behind}, diverged #{ahead} — not fast-forwardable, resolve manually" }
      end

      _, ff_err, ff_st = git_capture("-C", repo_path, "merge", "--ff-only", "origin/#{branch}")
      if ff_st.success?
        { repo: name, status: :fast_forwarded, message: "#{name}: fast-forwarded #{behind} commits" }
      else
        { repo: name, status: :ff_failed, message: "#{name}: merge --ff-only failed — #{ff_err.strip}" }
      end
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

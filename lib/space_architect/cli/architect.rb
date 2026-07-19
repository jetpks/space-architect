# frozen_string_literal: true

require "json"

module Space::Architect
  module CLI
    # Optional loop-phase DSL on the shared command base, read by
    # Space::Core::CLI::Help to group the help listing. A command may declare
    # `phase <order>, "<Label>"`; groups, and members within a group, sort by
    # <order>. Only architect commands declare one — space commands leave it nil
    # and render as the single ungrouped default listing (unchanged).
    class BaseCommand
      def self.phase(order = nil, label = nil)
        return @phase if order.nil?

        @phase = [order, label]
      end

      # Declares -m/--message and --message-from on a committing command. Every
      # loop command that commits takes both: the space's git log is the loop's
      # durable memory, so detailed messages are encouraged everywhere.
      def self.commit_message_options
        option :message, aliases: ["-m"], default: nil,
          desc: "Commit message: first line completes the subject after the canonical prefix, the rest becomes the body"
        option :message_from, default: nil,
          desc: "Read the commit message from this file (subject line + detailed body)"
      end

      private

      # Authored-content intake shared by section/verdict/brief: a file, an
      # inline flag, or stdin — canonical files are only ever written by the CLI.
      def read_body(from: nil, body: nil, stdin: false, what: "section body")
        if from
          begin
            return File.read(from)
          rescue Errno::ENOENT
            raise Space::Core::Error, "file for --from not found: #{from}; provide the #{what} via --from <file>, --body <text>, or --stdin"
          end
        end
        return body if body
        return $stdin.read if stdin

        raise Space::Core::Error, "provide the #{what} via --from <file>, --body <text>, or --stdin"
      end

      # Commit-message intake for commit_message_options: --message-from wins
      # over -m/--message; nil means the command's canonical default message.
      def read_commit_message(message: nil, message_from: nil)
        if message_from
          begin
            return File.read(message_from)
          rescue Errno::ENOENT
            raise Space::Core::Error, "file for --message-from not found: #{message_from}"
          end
        end

        message
      end
    end

    module Architect
      class Init < BaseCommand
        desc "Scaffold (or top up) the architect project: ARCHITECT.md, space.yaml project block, SessionStart hook"
        phase 50, "Project"
        argument :space, required: false, desc: "Space identifier (default: $PWD)"
        commit_message_options

        def call(space: nil, message: nil, message_from: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              path = project.init!(message: read_commit_message(message: message, message_from: message_from))
              terminal.say "Project ready: #{terminal.path(path)}"
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Ground < BaseCommand
        desc "Print grounding reads (ARCHITECT.md, BRIEF.md, in-flight iteration) to stdout"
        phase 51, "Project"
        argument :space, required: false, desc: "Space identifier (default: $PWD)"

        def call(space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            session_cwd = parse_session_cwd_from_stdin
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              content = project.ground(session_cwd: session_cwd)
              terminal.say content unless content.empty?
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end

        private

        # Read the session's working directory from the Claude Code hook JSON on stdin,
        # falling back to Dir.pwd when stdin is a tty or returns nothing (e.g. direct
        # terminal invocation, CI with /dev/null stdin, or in-process test invocation).
        def parse_session_cwd_from_stdin
          return Dir.pwd if $stdin.tty?
          line = $stdin.gets
          return Dir.pwd unless line
          JSON.parse(line.strip)["cwd"] || Dir.pwd
        rescue JSON::ParserError, TypeError
          Dir.pwd
        end
      end

      class New < BaseCommand
        desc "Scaffold the next iteration file (architecture/I<NN>-<iteration>.md)"
        phase 10, "Spec"
        argument :iteration, required: true,  desc: "Iteration name (kebab-case)"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        commit_message_options

        def call(iteration:, space: nil, message: nil, message_from: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              path = project.new_iteration!(iteration,
                message: read_commit_message(message: message, message_from: message_from))
              terminal.say "Iteration scaffolded: #{terminal.path(path)}"
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Status < BaseCommand
        desc "Show architect project state (read-only)"
        phase 52, "Project"
        argument :space, required: false, desc: "Space identifier (default: $PWD)"

        def call(space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              info = project.status
              block = info[:block]

              terminal.say "Project status:     #{block['status'] || '(none)'}"
              terminal.say "Current iteration:  #{block['current_iteration'] || '(none)'}"

              iterations = block["iterations"] || []
              if iterations.empty?
                terminal.say "Iterations:        (none)"
              else
                rows = iterations.map do |s|
                  nn = s["ordinal"] ? format("%02d", s["ordinal"]) : "-"
                  lane_list = s["lanes"] || []
                  lanes_str = lane_list.map do |l|
                    h = l["harness"] || "claude-code"
                    m = l["model"]   || Harness::CLAUDE_DEFAULT_MODEL
                    eff = l["effort"] ? "·#{l['effort']}" : ""
                    "#{l['name']}(#{l['repo']}·#{h}·#{m}#{eff})"
                  end.join(", ")
                  lanes = lane_list.any? { |l| l["variant"] } ? "variant: #{lanes_str}" : lanes_str
                  lanes = "#{lanes} → winner: #{s['winner']}" if s["winner"]
                  verdict_str = if s["verdict"] && s["verdict"] != "pending"
                    s["verdict"]
                  elsif (s["lanes"] || []).any? { |l| l["integration_branch"] }
                    "awaiting-verdict"
                  else
                    s["verdict"] || "-"
                  end
                  [nn, s["name"], s["freeze_sha"]&.[](0, 8) || "-", lanes, verdict_str]
                end
                terminal.say terminal.table(%w[II Iteration FreezeSHA Lanes Verdict], rows)
              end

              unless info[:iteration_files].empty?
                terminal.say "Iteration files:   #{info[:iteration_files].join(', ')}"
              end

              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Sync < BaseCommand
        desc "Sync tracked repo clones with their remotes (fast-forward only, no rebase/reset)"
        phase 53, "Project"
        argument :repo,  required: false, desc: "Repo name to sync (default: all tracked repos)"
        argument :space, required: false, desc: "Space identifier (default: $PWD)"

        def call(repo: nil, space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              results = project.sync_repos(repo_name: repo)
              results.each { |r| terminal.say r[:message] }
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Freeze < BaseCommand
        desc "Freeze the iteration's frozen region (Grounds/Specification/Acceptance Criteria) and record the freeze SHA"
        phase 12, "Spec"
        argument :iteration, required: true, desc: "Iteration name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :force, type: :boolean, default: false, desc: "Re-freeze even if the frozen region changed (pre-dispatch only)"
        commit_message_options

        def call(iteration:, space: nil, message: nil, message_from: nil, force: false, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              warnings = []
              sha = project.freeze!(iteration, warnings: warnings, force: force,
                message: read_commit_message(message: message, message_from: message_from))
              terminal.say "Frozen #{iteration} at #{sha}"
              warnings.each { |w| terminal.say "Warning: #{w}" }
              ac = project.acceptance_criteria(iteration)
              unless ac.to_s.strip.empty?
                terminal.say ""
                terminal.say "Frozen Acceptance Criteria (quote these verbatim when judging):"
                terminal.say ac
              end
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Verify < BaseCommand
        desc "Post-flight mechanical lane checks — frozen-untouched, no builder commits, report exists, in-bounds (reports only, no judgment)"
        phase 30, "Judge"
        argument :iteration,   required: true,  desc: "Iteration name"
        argument :space,       required: false, desc: "Space identifier (default: $PWD)"
        option   :commit_mode, default: nil,    desc: "Commit mode override (strict|conductor); overrides space.yaml commit_mode for this run"

        def call(iteration:, space: nil, commit_mode: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              terminal.say "Effective commit_mode: #{commit_mode}" if commit_mode
              results = project.verify(iteration, commit_mode: commit_mode)

              if results.empty?
                terminal.say "No lanes recorded for iteration '#{iteration}'"
                CLI.record_outcome(Outcome.new(exit_code: 0))
                next
              end

              rows = results.flat_map do |r|
                lane = r[:lane]
                c = r[:checks]
                [
                  [lane, "(a) frozen sections untouched", pass_fail(c[:frozen_untouched])],
                  [lane, "(b) no builder commits",        pass_fail(c[:no_builder_commits])],
                  [lane, "(c) scratch report exists",     pass_fail(c[:report_exists])],
                  [lane, "(d) in-bounds",                 pass_fail(c[:in_bounds])]
                ]
              end

              terminal.say terminal.table(%w[Lane Check Result], rows)
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end

        private

        def pass_fail(val)
          case val
          when true          then "PASS"
          when false         then "FAIL"
          when :no_touch_set then "WARN — no touch_set recorded"
          else                    "N/A"
          end
        end
      end

      class Dispatch < BaseCommand
        desc "Dispatch a builder for a lane (streams to build/<id>-<lane>/run.jsonl)"
        phase 21, "Build"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :lane,      required: true,  desc: "Lane name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :prompt,    default: nil,    desc: "Read the lane prompt from this file (copied byte-for-byte to build/<id>-<lane>/prompt.md)"
        option   :model,     default: nil,    desc: "Builder model to pin (default: the lane's model, else the reference default claude-sonnet-4-6). Any provider/tier; pin a full id, not a floating alias"
        option   :max_turns, default: "200",  desc: "Max turns for the builder"
        option   :harness,   default: nil,    desc: "Harness override (claude-code, opencode, pi)"
        option   :effort,    default: nil,    desc: "Reasoning effort override (opencode only; sets reasoningEffort in the model config)"
        option   :detach,    type: :boolean, default: false, desc: "Detach the builder process (returns immediately with PID; poll report for completion)"
        option   :timeout,   default: "14400", desc: "Wall-clock timeout in seconds (0 disables; default 4h); foreground only"
        option   :push_url,   default: nil,   desc: "HTTP endpoint for streaming push (POST body to this URL)"
        option   :push_token, default: nil,   desc: "Bearer token for push endpoint authorization"
        option   :push_host,  default: nil,   desc: "Base URL of the ingest server; the CLI creates a run via POST <host>/runs and streams to /runs/<id>/ingest (requires --push-token)"

        def call(iteration:, lane:, space: nil, prompt: nil, model: nil,
                 max_turns: "200", harness: nil, effort: nil, detach: false,
                 timeout: "14400", push_url: nil, push_token: nil, push_host: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              kwargs = { max_turns: max_turns.to_i, detach: detach }
              kwargs[:prompt]     = prompt          if prompt
              kwargs[:model]      = model           if model
              kwargs[:harness]    = harness         if harness
              kwargs[:effort]     = effort          if effort
              kwargs[:timeout]    = timeout.to_i    unless detach
              kwargs[:push_url]   = push_url        if push_url
              kwargs[:push_token] = push_token      if push_token
              kwargs[:push_host]  = push_host       if push_host
              res = project.dispatch(iteration, lane, **kwargs)
              terminal.say "Prompt:  #{prompt} → #{terminal.path(res[:prompt_copied])}" if res[:prompt_copied]
              if detach
                terminal.say "PID:     #{res[:pid]}"
                terminal.say "Run log: #{terminal.path(res[:run_log])}"
                terminal.say "Report:  #{terminal.path(res[:report])}"
                terminal.say "Dispatched detached — poll #{terminal.path(res[:report])} for completion"
                CLI.record_outcome(Outcome.new(exit_code: 0))
              elsif res[:timed_out]
                terminal.say "Run log: #{terminal.path(res[:run_log])}"
                terminal.say "Report:  #{terminal.path(res[:report])}"
                terminal.say "Builder TIMED OUT after #{timeout}s — process group killed. Re-dispatch (lanes are cheap)."
                CLI.record_outcome(Outcome.new(exit_code: res[:exit_code]))
              else
                terminal.say "Run log: #{terminal.path(res[:run_log])}"
                terminal.say "Report:  #{terminal.path(res[:report])}"
                terminal.say "Ingest URL:  #{res[:push_url]}" if res[:push_url]
                terminal.say "Builder exited with status #{res[:exit_code]}"
                CLI.record_outcome(Outcome.new(exit_code: res[:exit_code]))
              end
            end
          end
        end
      end

      class Provision < BaseCommand
        desc "Materialize declared lanes (worktree + lane/<id>-<lane> branch) from the frozen lane plan"
        phase 20, "Build"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :base,      default: nil,    desc: "Base ref override (default: project/<slug> HEAD if it exists, else the repo's default branch)"
        option   :lane,      default: nil,    desc: "Provision only this lane (default: all declared lanes)"
        option   :force,     type: :boolean, default: false, desc: "Clear and re-create a stale (unregistered) worktree directory"

        def call(iteration:, space: nil, base: nil, lane: nil, force: false, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              results = project.provision(iteration, base: base, lane: lane, force: force)
              if results.empty?
                terminal.say "No declared lanes to provision for '#{iteration}'"
              else
                results.each do |r|
                  state = r[:created] ? "created" : "already present"
                  terminal.say "#{r[:lane]}: #{terminal.path(r[:worktree])} (#{state})"
                end
              end
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Section < BaseCommand
        desc "Write a section of the iteration file and commit it (one call)"
        phase 11, "Spec"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :section,   required: true,  desc: "Section: grounds, specification, acceptance-criteria, prompt, verdict"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :from,   default: nil, desc: "Read the section body from this file"
        option   :body,   default: nil, desc: "Inline section body (one-liners)"
        option   :stdin,  type: :boolean, default: false, desc: "Read the section body from stdin"
        option   :append, type: :boolean, default: false, desc: "Append a ### <lane> subsection instead of replacing"
        option   :lane,   default: nil, desc: "Lane name for an appended ### subsection"
        option   :force,  type: :boolean, default: false, desc: "Write a frozen section (pre-dispatch only)"
        commit_message_options

        def call(iteration:, section:, space: nil, from: nil, body: nil, stdin: false, append: false, lane: nil,
                 message: nil, message_from: nil, force: false, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            content = read_body(from: from, body: body, stdin: stdin, what: "section body")
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              res = project.write_section!(iteration, section, body: content, append: append, lane: lane, force: force,
                message: read_commit_message(message: message, message_from: message_from))
              if res[:committed]
                terminal.say "Committed #{res[:heading]} → #{res[:sha][0, 8]}"
                terminal.say res[:diffstat] unless res[:diffstat].empty?
              else
                terminal.say "#{res[:heading]} written — no change to commit"
              end
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Verdict < BaseCommand
        desc "Record the architect's verdict decision (continue or kill) and write ## Verdict prose"
        phase 33, "Judge"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :decision,  required: true,  desc: "Decision: continue or kill"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :from,  default: nil,   desc: "Read the verdict body from this file"
        option   :body,  default: nil,   desc: "Inline verdict body"
        option   :stdin, type: :boolean, default: false, desc: "Read the verdict body from stdin"
        commit_message_options

        def call(iteration:, decision:, space: nil, from: nil, body: nil, stdin: false,
                 message: nil, message_from: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            content = read_body(from: from, body: body, stdin: stdin, what: "verdict body")
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              res = project.record_verdict!(iteration, decision: decision, body: content,
                message: read_commit_message(message: message, message_from: message_from))
              terminal.say "Verdict '#{res[:decision]}' recorded → #{res[:sha][0, 8]}"
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Evidence < BaseCommand
        desc "Transcribe a lane's scratch report VERBATIM into Builder Report and commit"
        phase 31, "Judge"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :lane,      default: nil,    desc: "Lane name (per-lane subsection; omit for a single-lane iteration)"
        commit_message_options

        def call(iteration:, space: nil, lane: nil, message: nil, message_from: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              res = project.transcribe_evidence!(iteration, lane: lane,
                message: read_commit_message(message: message, message_from: message_from))
              terminal.say "Transcribed #{res[:lines]} lines → #{res[:sha][0, 8]}"
              terminal.say "Builder STATUS: #{res[:status_line]}" if res[:status_line]
              terminal.say "Now rule on the builder's PHASE 0 disagreements in the Verdict (a later session)."
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Merge < BaseCommand
        desc "Integrate ONE judged-passing lane (merges --no-ff; runs no gates, makes no verdict)"
        phase 41, "Land"
        argument :iteration,   required: true,  desc: "Iteration name"
        argument :lane,        required: true,  desc: "Lane name (architect-judged passing)"
        argument :space,       required: false, desc: "Space identifier (default: $PWD)"
        option   :into,        required: false, desc: "Merge into this branch instead of the slug-derived project/<slug> default"
        option   :commit_mode, default: nil,    desc: "Commit mode override (strict|conductor); overrides space.yaml commit_mode for this run"
        commit_message_options

        def call(iteration:, lane:, space: nil, message: nil, message_from: nil, into: nil, commit_mode: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              r = project.merge_lane!(iteration, lane, into: into, commit_mode: commit_mode,
                message: read_commit_message(message: message, message_from: message_from))
              terminal.say "Merged #{lane} → #{r[:integration_branch]} (#{r[:merge_sha][0, 8]})"
              terminal.say r[:diffstat] unless r[:diffstat].empty?
              terminal.say "Gates NOT run — run `architect gate #{iteration}` against the integration branch."
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Integrate < BaseCommand
        desc "Integrate the architect-supplied set of passing lanes, in order (stops on conflict)"
        phase 40, "Land"
        argument :iteration,   required: true,  desc: "Iteration name"
        argument :space,       required: false, desc: "Space identifier (default: $PWD)"
        option   :lanes,       required: false, desc: "Comma-separated passing lane names (you decide the set)"
        option   :teardown,    type: :boolean, default: false, desc: "Remove worktrees + delete lane branches after merge"
        option   :commit_mode, default: nil,    desc: "Commit mode override (strict|conductor); overrides space.yaml commit_mode for this run"
        option   :into,        required: false, desc: "Merge into this branch instead of the slug-derived project/<slug> default"
        commit_message_options

        def call(iteration:, space: nil, lanes: nil, teardown: false, message: nil, message_from: nil, commit_mode: nil, into: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            lane_names = lanes.to_s.split(",").map(&:strip).reject(&:empty?)
            raise Space::Core::Error, "integrate needs --lanes <set>, or --teardown for teardown-only" \
              if lane_names.empty? && !teardown

            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              results = project.integrate!(iteration, lanes: lane_names, teardown: teardown,
                message: read_commit_message(message: message, message_from: message_from),
                commit_mode: commit_mode, into: into)
              if lane_names.empty?
                if results.empty?
                  terminal.say "Nothing to tear down for #{iteration}"
                else
                  results.each do |r|
                    terminal.say "Tore down #{r[:lane]} (removed worktree, deleted #{r[:lane_branch]})"
                  end
                end
              else
                results.each do |r|
                  terminal.say "Merged #{r[:lane]} → #{r[:integration_branch]} (#{r[:merge_sha][0, 8]})"
                end
                terminal.say "Gates NOT run — run `architect gate #{iteration}`; the verdict is the next session's."
              end
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Gate < BaseCommand
        desc "Run the frozen Acceptance Criteria gate commands and report PASS/FAIL"
        phase 32, "Judge"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :lane,      required: false, desc: "Run in a lane worktree (default: the integration repo)"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"

        def call(iteration:, lane: nil, space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              results = project.run_gates(iteration, lane: lane)
              results.each do |r|
                marker = r[:status] == :pass ? "PASS" : "FAIL"
                terminal.say ""
                terminal.say "── #{r[:ac].empty? ? "(gate)" : r[:ac]}: #{r[:cmd]}  (exit #{r[:exit_code]})  [#{marker}]"
                terminal.say "   reason: #{r[:reason]}" if r[:status] == :fail && !r[:reason].to_s.empty?
                terminal.say r[:stdout].rstrip unless r[:stdout].strip.empty?
                terminal.say r[:stderr].rstrip unless r[:stderr].strip.empty?
              end
              terminal.say ""
              terminal.say "Mechanical gate results above; the Acceptance-Criteria verdict — necessary, not sufficient — remains the architect's."
              any_fail = results.any? { |r| r[:status] == :fail }
              CLI.record_outcome(Outcome.new(exit_code: any_fail ? 1 : 0))
            end
          end
        end
      end

      class BugReport < BaseCommand
        desc "Generate a prefilled GitHub issue template for filing bugs against space-architect"
        phase 54, "Project"

        def call(**opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            space = store.find.value_or(nil)
            result = Space::Architect::BugReport.generate(
              space: space,
              env: project_config.env
            )
            terminal.say "Fill the placeholders in #{terminal.path(result[:body_path].to_s)}, then run:"
            terminal.say result[:command]
            terminal.say ""
            terminal.say "Diagnostics:"
            terminal.say "  space-architect #{Space::Core::VERSION}"
            terminal.say "  ruby #{RUBY_VERSION} (#{RUBY_PLATFORM})"
            terminal.say "  space: #{space.id} — #{space.title}" if space
            CLI.record_outcome(Outcome.new(exit_code: 0))
          end
        end
      end

      class InstallSkills < BaseCommand
        desc "Install bundled skills (architect, architect-research, architect-vocabulary) for a harness"
        phase 53, "Project"
        option :provider, default: "claude", desc: "Harness: claude, codex, opencode, pi"
        option :project, type: :boolean, default: false, desc: "Install to CWD instead of global"
        option :force,   type: :boolean, default: false, desc: "Overwrite existing skills that differ"
        option :dry_run, type: :boolean, default: false, desc: "Print what would happen without writing files"

        def call(provider: "claude", project: false, force: false, dry_run: false, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            result = SkillInstaller.install(provider, project: project, force: force,
                                             env: project_config.env, dry_run: dry_run)
            verb = dry_run ? "Would install" : "Installed"
            terminal.say "#{verb} skills for #{provider} → #{terminal.path(result[:dest_root])}"
            result[:skills].each do |s|
              terminal.say "  #{s[:name]}: #{terminal.style_skill_action(s[:action])} (#{terminal.path(s[:path])})"
            end
            CLI.record_outcome(Outcome.new(exit_code: 0))
          end
        end
      end

      module Worktree
        class Add < BaseCommand
          desc "Create a worktree for a lane"
          argument :repo,      required: true, desc: "Repo name (under repos/)"
          argument :iteration, required: true, desc: "Iteration name"
          argument :lane,      required: true, desc: "Lane name"
          option   :base,      default: nil,          desc: "Base ref (default: HEAD of repo)"
          option   :harness,   default: "claude-code", desc: "Harness (claude-code, opencode, pi)"
          option   :model,     default: nil,           desc: "Model (required for opencode)"
          option   :effort,    default: nil,           desc: "Reasoning effort (opencode only; sets reasoningEffort in the model config)"
          option   :touch,     default: nil,           desc: "Comma-separated file globs the lane may touch (records its touch_set for in-bounds + merge checks)"
          option   :force,     type: :boolean, default: false, desc: "Clear and re-create a stale (unregistered) worktree directory"

          def call(repo:, iteration:, lane:, base: nil, harness: "claude-code", model: nil, effort: nil, touch: nil, force: false, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find) do |sp|
                project = ArchitectProject.new(space: sp)
                touch_set = touch ? touch.split(",").map(&:strip).reject(&:empty?) : nil
                result = project.worktree_add(repo, iteration, lane, base: base,
                                             harness: harness, model: model, effort: effort, touch: touch_set, force: force)
                terminal.say "Worktree: #{terminal.path(result[:worktree])}"
                terminal.say "Base SHA: #{result[:base_sha]}"
                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end

        class Remove < BaseCommand
          desc "Remove a lane worktree"
          argument :iteration, required: true, desc: "Iteration name"
          argument :lane,      required: true, desc: "Lane name"

          def call(iteration:, lane:, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find) do |sp|
                project = ArchitectProject.new(space: sp)
                project.worktree_remove(iteration, lane)
                terminal.say "Removed worktree for #{iteration}/#{lane}"
                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end

        class List < BaseCommand
          desc "List active architect worktrees"

          def call(**opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find) do |sp|
                project = ArchitectProject.new(space: sp)
                worktrees = project.worktree_list
                if worktrees.empty?
                  terminal.say "No active architect worktrees"
                else
                  worktrees.each { |wt| terminal.say wt }
                end
                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end
      end

      module Variant
        class Add < BaseCommand
          desc "Create a variant set (competing lanes over one frozen spec)"
          argument :repo,      required: true,  desc: "Repo name (under repos/)"
          argument :iteration, required: true,  desc: "Iteration name"
          argument :space,     required: false, desc: "Space identifier (default: $PWD)"
          option   :pairs,     required: true,  desc: "Comma-separated harness[:model] pairs (e.g. claude-code,opencode:fireworks-ai/accounts/fireworks/models/glm-5p2)"
          option   :base,      default: nil,    desc: "Base ref (default: HEAD of repo)"
          option   :prompt,    default: nil,    desc: "Prompt file to fan-out byte-identical to each variant"

          def call(repo:, iteration:, space: nil, pairs:, base: nil, prompt: nil, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find(space)) do |sp|
                parsed_pairs = pairs.to_s.split(",").map do |spec|
                  harness, model = spec.split(":", 2)
                  model = nil if model.nil? || model.empty?
                  [harness, model]
                end

                project = ArchitectProject.new(space: sp)
                variants = project.variant_add(repo, iteration, parsed_pairs, base: base, prompt: prompt)
                variants.each do |v|
                  terminal.say "#{v[:name]} · #{v[:harness]} · #{v[:model] || "(default)"} · #{terminal.path(v[:worktree])}"
                end
                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end

        class Promote < BaseCommand
          desc "Promote one variant of a variant set as the winner"
          argument :iteration, required: true,  desc: "Iteration name"
          argument :winner,    required: true,  desc: "Variant lane name to promote (e.g. v02)"
          argument :space,     required: false, desc: "Space identifier (default: $PWD)"

          def call(iteration:, winner:, space: nil, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find(space)) do |sp|
                project = ArchitectProject.new(space: sp)
                result = project.variant_promote(iteration, winner)
                if result[:discarded].any?
                  terminal.say "Promoted #{result[:winner]} (discarded: #{result[:discarded].join(', ')})"
                else
                  terminal.say "Promoted #{result[:winner]}"
                end
                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end

        class Compare < BaseCommand
          desc "Compare variants of an iteration's variant set (read-only)"
          argument :iteration, required: true,  desc: "Iteration name"
          argument :space,     required: false, desc: "Space identifier (default: $PWD)"

          def call(iteration:, space: nil, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find(space)) do |sp|
                project = ArchitectProject.new(space: sp)
                info = project.variant_compare(iteration)

                terminal.say "Variant comparison: #{iteration} (freeze #{info[:freeze_sha]&.[](0, 8) || "-"})"
                terminal.say "Winner: #{info[:winner] || '(none)'}"
                terminal.say ""
                rows = info[:variants].map do |v|
                  [
                    v[:name],
                    v[:harness],
                    v[:model] || "(default)",
                    v[:effort] || "-",
                    v[:status] == "winner" ? "WINNER" : v[:status],
                    v[:integration_branch] || "-",
                    v[:base_sha]&.[](0, 8) || "-"
                  ]
                end
                terminal.say terminal.table(%w[Variant Harness Model Effort Status Integration Base], rows)

                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end
      end

      module Brief
        class New < BaseCommand
          desc "Write the durable project brief (architecture/BRIEF.md) — authored via --from/--stdin, or a placeholder template"
          argument :space, required: false, desc: "Space identifier (default: $PWD)"
          option   :force, type: :boolean, default: false, desc: "Overwrite an existing BRIEF.md"
          option   :from,  default: nil,   desc: "Read the authored brief body from this file"
          option   :stdin, type: :boolean, default: false, desc: "Read the authored brief body from stdin"
          commit_message_options

          def call(space: nil, force: false, from: nil, stdin: false, message: nil, message_from: nil, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              content = (from || stdin) ? read_body(from: from, stdin: stdin, what: "brief body") : nil
              render(store.find(space)) do |sp|
                project = ArchitectProject.new(space: sp)
                path = project.brief_new!(force: force, content: content,
                  message: read_commit_message(message: message, message_from: message_from))
                note = content ? "" : " (template — Read it before editing)"
                terminal.say "Brief ready: #{terminal.path(path)}#{note}"
                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end
      end
    end
  end
end

# Loop-phase declarations above sort the architect help listing; its namespaces
# (brief/worktree/variant/research) declare no phase and list under this header.
Space::Core::CLI::Help.trailing_group_label = "Groups"

Space::Architect::CLI::Registry.register "init",   Space::Architect::CLI::Architect::Init
Space::Architect::CLI::Registry.register "ground", Space::Architect::CLI::Architect::Ground
Space::Architect::CLI::Registry.register "new",    Space::Architect::CLI::Architect::New
Space::Architect::CLI::Registry.register "status", Space::Architect::CLI::Architect::Status
Space::Architect::CLI::Registry.register "sync",   Space::Architect::CLI::Architect::Sync
Space::Architect::CLI::Registry.register "freeze", Space::Architect::CLI::Architect::Freeze
Space::Architect::CLI::Registry.register "verify", Space::Architect::CLI::Architect::Verify
Space::Architect::CLI::Registry.register "provision", Space::Architect::CLI::Architect::Provision
Space::Architect::CLI::Registry.register "dispatch", Space::Architect::CLI::Architect::Dispatch
Space::Architect::CLI::Registry.register "section",   Space::Architect::CLI::Architect::Section
Space::Architect::CLI::Registry.register "verdict",   Space::Architect::CLI::Architect::Verdict
Space::Architect::CLI::Registry.register "evidence",  Space::Architect::CLI::Architect::Evidence
Space::Architect::CLI::Registry.register "merge",     Space::Architect::CLI::Architect::Merge
Space::Architect::CLI::Registry.register "integrate", Space::Architect::CLI::Architect::Integrate
Space::Architect::CLI::Registry.register "gate",      Space::Architect::CLI::Architect::Gate
Space::Architect::CLI::Registry.register "install-skills", Space::Architect::CLI::Architect::InstallSkills
Space::Architect::CLI::Registry.register "bug-report",     Space::Architect::CLI::Architect::BugReport
Space::Architect::CLI::Registry.register "brief" do |b|
  b.register "new", Space::Architect::CLI::Architect::Brief::New
end
Space::Architect::CLI::Registry.register "worktree" do |wt|
  wt.register "add",    Space::Architect::CLI::Architect::Worktree::Add
  wt.register "remove", Space::Architect::CLI::Architect::Worktree::Remove
  wt.register "list",   Space::Architect::CLI::Architect::Worktree::List
end
Space::Architect::CLI::Registry.register "variant" do |v|
  v.register "add",     Space::Architect::CLI::Architect::Variant::Add
  v.register "promote", Space::Architect::CLI::Architect::Variant::Promote
  v.register "compare", Space::Architect::CLI::Architect::Variant::Compare
end

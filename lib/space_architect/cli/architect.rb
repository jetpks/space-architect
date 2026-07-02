# frozen_string_literal: true

require "json"

module Space::Architect
  module CLI
    module Architect
      class Init < BaseCommand
        desc "Scaffold (or top up) the architect project: ARCHITECT.md, space.yaml project block, SessionStart hook"
        argument :space, required: false, desc: "Space identifier (default: $PWD)"

        def call(space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              path = project.init!
              terminal.say "Project ready: #{terminal.path(path)}"
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Ground < BaseCommand
        desc "Print grounding reads (ARCHITECT.md, BRIEF.md, in-flight iteration) to stdout"
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
        argument :iteration, required: true,  desc: "Iteration name (kebab-case)"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"

        def call(iteration:, space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              path = project.new_iteration!(iteration)
              terminal.say "Iteration scaffolded: #{terminal.path(path)}"
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Status < BaseCommand
        desc "Show architect project state (read-only)"
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

      class Freeze < BaseCommand
        desc "Freeze the iteration's frozen region (Grounds/Specification/Acceptance Criteria) and record the freeze SHA"
        argument :iteration, required: true, desc: "Iteration name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"

        def call(iteration:, space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              warnings = []
              sha = project.freeze!(iteration, warnings: warnings)
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
        argument :iteration, required: true, desc: "Iteration name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"

        def call(iteration:, space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              results = project.verify(iteration)

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
        argument :iteration, required: true,  desc: "Iteration name"
        argument :lane,      required: true,  desc: "Lane name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :model,     default: nil,    desc: "Builder model to pin (default: the lane's model, else the reference default claude-sonnet-4-6). Any provider/tier; pin a full id, not a floating alias"
        option   :max_turns, default: "200",  desc: "Max turns for the builder"
        option   :harness,   default: nil,    desc: "Harness override (claude-code, opencode)"
        option   :effort,    default: nil,    desc: "Reasoning effort override (opencode only; sets reasoningEffort in the model config)"
        option   :detach,    type: :boolean, default: false, desc: "Detach the builder process (returns immediately with PID; poll report for completion)"
        option   :timeout,   default: "14400", desc: "Wall-clock timeout in seconds (0 disables; default 4h); foreground only"
        option   :push_url,   default: nil,   desc: "HTTP endpoint for streaming push (POST body to this URL)"
        option   :push_token, default: nil,   desc: "Bearer token for push endpoint authorization"
        option   :push_host,  default: nil,   desc: "Base URL of the ingest server; the CLI creates a run via POST <host>/runs and streams to /runs/<id>/ingest (requires --push-token)"

        def call(iteration:, lane:, space: nil, model: nil,
                 max_turns: "200", harness: nil, effort: nil, detach: false,
                 timeout: "14400", push_url: nil, push_token: nil, push_host: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              kwargs = { max_turns: max_turns.to_i, detach: detach }
              kwargs[:model]      = model           if model
              kwargs[:harness]    = harness         if harness
              kwargs[:effort]     = effort          if effort
              kwargs[:timeout]    = timeout.to_i    unless detach
              kwargs[:push_url]   = push_url        if push_url
              kwargs[:push_token] = push_token      if push_token
              kwargs[:push_host]  = push_host       if push_host
              res = project.dispatch(iteration, lane, **kwargs)
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

      class Section < BaseCommand
        desc "Write a section of the iteration file and commit it (one call)"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :section,   required: true,  desc: "Section: grounds, specification, prompt, verdict"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :from,   default: nil, desc: "Read the section body from this file"
        option   :body,   default: nil, desc: "Inline section body (one-liners)"
        option   :stdin,  type: :boolean, default: false, desc: "Read the section body from stdin"
        option   :append, type: :boolean, default: false, desc: "Append a ### <lane> subsection instead of replacing"
        option   :lane,   default: nil, desc: "Lane name for an appended ### subsection"

        def call(iteration:, section:, space: nil, from: nil, body: nil, stdin: false, append: false, lane: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            content = read_section_body(from: from, body: body, stdin: stdin)
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              res = project.write_section!(iteration, section, body: content, append: append, lane: lane)
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

        private

        def read_section_body(from:, body:, stdin:)
          return File.read(from) if from
          return body if body
          return $stdin.read if stdin
          raise Space::Core::Error, "provide the section body via --from <file>, --body <text>, or --stdin"
        end
      end

      class Verdict < BaseCommand
        desc "Record the architect's verdict decision (continue or kill) and write ## Verdict prose"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :decision,  required: true,  desc: "Decision: continue or kill"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :from,  default: nil,   desc: "Read the verdict body from this file"
        option   :body,  default: nil,   desc: "Inline verdict body"
        option   :stdin, type: :boolean, default: false, desc: "Read the verdict body from stdin"

        def call(iteration:, decision:, space: nil, from: nil, body: nil, stdin: false, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            content = read_section_body(from: from, body: body, stdin: stdin)
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              res = project.record_verdict!(iteration, decision: decision, body: content)
              terminal.say "Verdict '#{res[:decision]}' recorded → #{res[:sha][0, 8]}"
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end

        private

        def read_section_body(from:, body:, stdin:)
          return File.read(from) if from
          return body if body
          return $stdin.read if stdin
          raise Space::Core::Error, "provide the verdict body via --from <file>, --body <text>, or --stdin"
        end
      end

      class Evidence < BaseCommand
        desc "Transcribe a lane's scratch report VERBATIM into Builder Report and commit"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :lane,      default: nil,    desc: "Lane name (per-lane subsection; omit for a single-lane iteration)"

        def call(iteration:, space: nil, lane: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              res = project.transcribe_evidence!(iteration, lane: lane)
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
        argument :iteration, required: true,  desc: "Iteration name"
        argument :lane,      required: true,  desc: "Lane name (architect-judged passing)"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :message,   default: nil,    desc: "Commit message for the lane's working-tree changes"

        def call(iteration:, lane:, space: nil, message: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              r = project.merge_lane!(iteration, lane, message: message)
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
        argument :iteration, required: true,  desc: "Iteration name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :lanes,     required: true,  desc: "Comma-separated passing lane names (you decide the set)"
        option   :teardown,  type: :boolean, default: false, desc: "Remove worktrees + delete lane branches after merge"

        def call(iteration:, space: nil, lanes:, teardown: false, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              lane_names = lanes.to_s.split(",").map(&:strip).reject(&:empty?)
              results = project.integrate!(iteration, lanes: lane_names, teardown: teardown)
              results.each do |r|
                terminal.say "Merged #{r[:lane]} → #{r[:integration_branch]} (#{r[:merge_sha][0, 8]})"
              end
              terminal.say "Gates NOT run — run `architect gate #{iteration}`; the verdict is the next session's."
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Land < BaseCommand
        desc "Generate the end-of-project paste-and-run block (no push, no gh — prints commands to run)"
        argument :space, required: false, desc: "Space identifier (default: $PWD)"

        def call(space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              project = ArchitectProject.new(space: sp)
              results = project.land(env: project_config.env)
              results.each do |r|
                terminal.say "Fill the placeholders in #{terminal.path(r[:body_file])}, then run:"
                terminal.say ""
                terminal.say r[:cd_line]
                terminal.say r[:push_line]
                terminal.say r[:command]
              end
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Gate < BaseCommand
        desc "Run the frozen Acceptance Criteria gate commands and report PASS/FAIL"
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
          option   :harness,   default: "claude-code", desc: "Harness (claude-code, opencode)"
          option   :model,     default: nil,           desc: "Model (required for opencode)"
          option   :effort,    default: nil,           desc: "Reasoning effort (opencode only; sets reasoningEffort in the model config)"
          option   :touch,     default: nil,           desc: "Comma-separated file globs the lane may touch (records its touch_set for in-bounds + merge checks)"

          def call(repo:, iteration:, lane:, base: nil, harness: "claude-code", model: nil, effort: nil, touch: nil, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find) do |sp|
                project = ArchitectProject.new(space: sp)
                touch_set = touch ? touch.split(",").map(&:strip).reject(&:empty?) : nil
                result = project.worktree_add(repo, iteration, lane, base: base,
                                             harness: harness, model: model, effort: effort, touch: touch_set)
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
          desc "Scaffold the durable project brief (architecture/BRIEF.md)"
          argument :space, required: false, desc: "Space identifier (default: $PWD)"
          option   :force, type: :boolean, default: false, desc: "Overwrite an existing BRIEF.md"

          def call(space: nil, force: false, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find(space)) do |sp|
                project = ArchitectProject.new(space: sp)
                path = project.brief_new!(force: force)
                terminal.say "Brief ready: #{terminal.path(path)}"
                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end
      end
    end
  end
end

Space::Architect::CLI::Registry.register "init",   Space::Architect::CLI::Architect::Init
Space::Architect::CLI::Registry.register "ground", Space::Architect::CLI::Architect::Ground
Space::Architect::CLI::Registry.register "new",    Space::Architect::CLI::Architect::New
Space::Architect::CLI::Registry.register "status", Space::Architect::CLI::Architect::Status
Space::Architect::CLI::Registry.register "freeze", Space::Architect::CLI::Architect::Freeze
Space::Architect::CLI::Registry.register "verify", Space::Architect::CLI::Architect::Verify
Space::Architect::CLI::Registry.register "dispatch", Space::Architect::CLI::Architect::Dispatch
Space::Architect::CLI::Registry.register "section",   Space::Architect::CLI::Architect::Section
Space::Architect::CLI::Registry.register "verdict",   Space::Architect::CLI::Architect::Verdict
Space::Architect::CLI::Registry.register "evidence",  Space::Architect::CLI::Architect::Evidence
Space::Architect::CLI::Registry.register "merge",     Space::Architect::CLI::Architect::Merge
Space::Architect::CLI::Registry.register "integrate", Space::Architect::CLI::Architect::Integrate
Space::Architect::CLI::Registry.register "land",      Space::Architect::CLI::Architect::Land
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

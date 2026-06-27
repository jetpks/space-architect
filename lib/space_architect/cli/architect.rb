# frozen_string_literal: true

module Space::Architect
  module CLI
    module Architect
      class Init < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Scaffold architect mission memory in the current space"
        argument :space, required: false, desc: "Space identifier (default: $PWD)"

        def call(space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              mission = ArchitectMission.new(space: sp)
              path = mission.init!
              terminal.say "Mission ready: #{terminal.path(path)}"
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class New < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Scaffold the next iteration file (architecture/I<NN>-<iteration>.md)"
        argument :iteration, required: true,  desc: "Iteration name (kebab-case)"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"

        def call(iteration:, space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              mission = ArchitectMission.new(space: sp)
              path = mission.new_iteration!(iteration)
              terminal.say "Iteration scaffolded: #{terminal.path(path)}"
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Status < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Show architect mission state (read-only)"
        argument :space, required: false, desc: "Space identifier (default: $PWD)"

        def call(space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              mission = ArchitectMission.new(space: sp)
              info = mission.status
              block = info[:block]

              terminal.say "Mission status:     #{block['status'] || '(none)'}"
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
                  [nn, s["name"], s["freeze_sha"]&.[](0, 8) || "-", lanes, s["verdict"] || "-"]
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

      class Freeze < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Freeze gates for an iteration"
        argument :iteration, required: true, desc: "Iteration name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"

        def call(iteration:, space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              mission = ArchitectMission.new(space: sp)
              sha = mission.freeze!(iteration)
              terminal.say "Frozen #{iteration} at #{sha}"
              ac = mission.acceptance_criteria(iteration)
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

      class Verify < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Post-flight mechanical checks for an iteration (reports only, no judgment)"
        argument :iteration, required: true, desc: "Iteration name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"

        def call(iteration:, space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              mission = ArchitectMission.new(space: sp)
              results = mission.verify(iteration)

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
          when true  then "PASS"
          when false then "FAIL"
          else            "N/A"
          end
        end
      end

      class Dispatch < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Dispatch a builder for a lane (streams to build/<id>-<lane>/run.jsonl)"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :lane,      required: true,  desc: "Lane name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :model,     default: nil,    desc: "Model to use (default: lane entry or claude-sonnet-4-6)"
        option   :max_turns, default: "200",  desc: "Max turns for the builder"
        option   :harness,   default: nil,    desc: "Harness override (claude-code, opencode)"
        option   :effort,    default: nil,    desc: "Reasoning effort override (opencode only; sets reasoningEffort in the model config)"
        option   :detach,    type: :boolean, default: false, desc: "Detach the builder process (returns immediately with PID; poll report for completion)"

        def call(iteration:, lane:, space: nil, model: nil,
                 max_turns: "200", harness: nil, effort: nil, detach: false, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              mission = ArchitectMission.new(space: sp)
              kwargs = { max_turns: max_turns.to_i, detach: detach }
              kwargs[:model]   = model   if model
              kwargs[:harness] = harness if harness
              kwargs[:effort]  = effort  if effort
              res = mission.dispatch(iteration, lane, **kwargs)
              if detach
                terminal.say "PID:     #{res[:pid]}"
                terminal.say "Run log: #{terminal.path(res[:run_log])}"
                terminal.say "Report:  #{terminal.path(res[:report])}"
                terminal.say "Dispatched detached — poll #{terminal.path(res[:report])} for completion"
                CLI.record_outcome(Outcome.new(exit_code: 0))
              else
                terminal.say "Run log: #{terminal.path(res[:run_log])}"
                terminal.say "Report:  #{terminal.path(res[:report])}"
                terminal.say "Builder exited with status #{res[:exit_code]}"
                CLI.record_outcome(Outcome.new(exit_code: res[:exit_code]))
              end
            end
          end
        end
      end

      class Section < Dry::CLI::Command
        include GlobalOptions
        include Helpers

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
              mission = ArchitectMission.new(space: sp)
              res = mission.write_section!(iteration, section, body: content, append: append, lane: lane)
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

      class Evidence < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Transcribe a lane's scratch report VERBATIM into Builder Report and commit"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :lane,      default: nil,    desc: "Lane name (per-lane subsection; omit for a single-lane iteration)"

        def call(iteration:, space: nil, lane: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              mission = ArchitectMission.new(space: sp)
              res = mission.transcribe_evidence!(iteration, lane: lane)
              terminal.say "Transcribed #{res[:lines]} lines → #{res[:sha][0, 8]}"
              terminal.say "Builder STATUS: #{res[:status_line]}" if res[:status_line]
              terminal.say "Now rule on the builder's PHASE 0 disagreements in the Verdict (a later session)."
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Merge < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Integrate ONE judged-passing lane (merges --no-ff; runs no gates, makes no verdict)"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :lane,      required: true,  desc: "Lane name (architect-judged passing)"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :message,   default: nil,    desc: "Commit message for the lane's working-tree changes"

        def call(iteration:, lane:, space: nil, message: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              mission = ArchitectMission.new(space: sp)
              r = mission.merge_lane!(iteration, lane, message: message)
              terminal.say "Merged #{lane} → #{r[:integration_branch]} (#{r[:merge_sha][0, 8]})"
              terminal.say r[:diffstat] unless r[:diffstat].empty?
              terminal.say "Gates NOT run — run `architect gate #{iteration}` against the integration branch."
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Integrate < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Integrate the architect-supplied set of passing lanes, in order (stops on conflict)"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"
        option   :lanes,     required: true,  desc: "Comma-separated passing lane names (you decide the set)"
        option   :teardown,  type: :boolean, default: false, desc: "Remove worktrees + delete lane branches after merge"

        def call(iteration:, space: nil, lanes:, teardown: false, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              mission = ArchitectMission.new(space: sp)
              lane_names = lanes.to_s.split(",").map(&:strip).reject(&:empty?)
              results = mission.integrate!(iteration, lanes: lane_names, teardown: teardown)
              results.each do |r|
                terminal.say "Merged #{r[:lane]} → #{r[:integration_branch]} (#{r[:merge_sha][0, 8]})"
              end
              terminal.say "Gates NOT run — run `architect gate #{iteration}`; the verdict is the next session's."
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Gate < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Run the frozen Acceptance Criteria gate commands and stream raw output (no PASS/FAIL)"
        argument :iteration, required: true,  desc: "Iteration name"
        argument :lane,      required: false, desc: "Run in a lane worktree (default: the integration repo)"
        argument :space,     required: false, desc: "Space identifier (default: $PWD)"

        def call(iteration:, lane: nil, space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.find(space)) do |sp|
              mission = ArchitectMission.new(space: sp)
              results = mission.run_gates(iteration, lane: lane)
              results.each do |r|
                terminal.say ""
                terminal.say "── #{r[:ac].empty? ? "(gate)" : r[:ac]}: #{r[:command]}  (exit #{r[:exit_code]})"
                terminal.say r[:stdout].rstrip unless r[:stdout].strip.empty?
                terminal.say r[:stderr].rstrip unless r[:stderr].strip.empty?
              end
              terminal.say ""
              terminal.say "Raw gate output above — the PASS/FAIL/INVALID verdict is yours, read against the frozen thresholds."
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class InstallSkills < Dry::CLI::Command
        include GlobalOptions
        include Helpers

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
        class Add < Dry::CLI::Command
          include GlobalOptions
          include Helpers

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
                mission = ArchitectMission.new(space: sp)
                touch_set = touch ? touch.split(",").map(&:strip).reject(&:empty?) : nil
                result = mission.worktree_add(repo, iteration, lane, base: base,
                                             harness: harness, model: model, effort: effort, touch: touch_set)
                terminal.say "Worktree: #{terminal.path(result[:worktree])}"
                terminal.say "Base SHA: #{result[:base_sha]}"
                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end

        class Remove < Dry::CLI::Command
          include GlobalOptions
          include Helpers

          desc "Remove a lane worktree"
          argument :iteration, required: true, desc: "Iteration name"
          argument :lane,      required: true, desc: "Lane name"

          def call(iteration:, lane:, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find) do |sp|
                mission = ArchitectMission.new(space: sp)
                mission.worktree_remove(iteration, lane)
                terminal.say "Removed worktree for #{iteration}/#{lane}"
                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end

        class List < Dry::CLI::Command
          include GlobalOptions
          include Helpers

          desc "List active architect worktrees"

          def call(**opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find) do |sp|
                mission = ArchitectMission.new(space: sp)
                worktrees = mission.worktree_list
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
        class Add < Dry::CLI::Command
          include GlobalOptions
          include Helpers

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

                mission = ArchitectMission.new(space: sp)
                variants = mission.variant_add(repo, iteration, parsed_pairs, base: base, prompt: prompt)
                variants.each do |v|
                  terminal.say "#{v[:name]} · #{v[:harness]} · #{v[:model] || "(default)"} · #{terminal.path(v[:worktree])}"
                end
                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end

        class Promote < Dry::CLI::Command
          include GlobalOptions
          include Helpers

          desc "Promote one variant of a variant set as the winner"
          argument :iteration, required: true,  desc: "Iteration name"
          argument :winner,    required: true,  desc: "Variant lane name to promote (e.g. v02)"
          argument :space,     required: false, desc: "Space identifier (default: $PWD)"

          def call(iteration:, winner:, space: nil, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find(space)) do |sp|
                mission = ArchitectMission.new(space: sp)
                result = mission.variant_promote(iteration, winner)
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

        class Compare < Dry::CLI::Command
          include GlobalOptions
          include Helpers

          desc "Compare variants of an iteration's variant set (read-only)"
          argument :iteration, required: true,  desc: "Iteration name"
          argument :space,     required: false, desc: "Space identifier (default: $PWD)"

          def call(iteration:, space: nil, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find(space)) do |sp|
                mission = ArchitectMission.new(space: sp)
                info = mission.variant_compare(iteration)

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
        class New < Dry::CLI::Command
          include GlobalOptions
          include Helpers

          desc "Scaffold the durable mission brief (architecture/BRIEF.md)"
          argument :space, required: false, desc: "Space identifier (default: $PWD)"
          option   :force, type: :boolean, default: false, desc: "Overwrite an existing BRIEF.md"

          def call(space: nil, force: false, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find(space)) do |sp|
                mission = ArchitectMission.new(space: sp)
                path = mission.brief_new!(force: force)
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
Space::Architect::CLI::Registry.register "new",    Space::Architect::CLI::Architect::New
Space::Architect::CLI::Registry.register "status", Space::Architect::CLI::Architect::Status
Space::Architect::CLI::Registry.register "freeze", Space::Architect::CLI::Architect::Freeze
Space::Architect::CLI::Registry.register "verify", Space::Architect::CLI::Architect::Verify
Space::Architect::CLI::Registry.register "dispatch", Space::Architect::CLI::Architect::Dispatch
Space::Architect::CLI::Registry.register "section",   Space::Architect::CLI::Architect::Section
Space::Architect::CLI::Registry.register "evidence",  Space::Architect::CLI::Architect::Evidence
Space::Architect::CLI::Registry.register "merge",     Space::Architect::CLI::Architect::Merge
Space::Architect::CLI::Registry.register "integrate", Space::Architect::CLI::Architect::Integrate
Space::Architect::CLI::Registry.register "gate",      Space::Architect::CLI::Architect::Gate
Space::Architect::CLI::Registry.register "install-skills", Space::Architect::CLI::Architect::InstallSkills
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

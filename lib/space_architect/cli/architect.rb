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

          def call(repo:, iteration:, lane:, base: nil, harness: "claude-code", model: nil, effort: nil, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find) do |sp|
                mission = ArchitectMission.new(space: sp)
                result = mission.worktree_add(repo, iteration, lane, base: base,
                                             harness: harness, model: model, effort: effort)
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
    end
  end
end

Space::Architect::CLI::Registry.register "init",   Space::Architect::CLI::Architect::Init
Space::Architect::CLI::Registry.register "new",    Space::Architect::CLI::Architect::New
Space::Architect::CLI::Registry.register "status", Space::Architect::CLI::Architect::Status
Space::Architect::CLI::Registry.register "freeze", Space::Architect::CLI::Architect::Freeze
Space::Architect::CLI::Registry.register "verify", Space::Architect::CLI::Architect::Verify
Space::Architect::CLI::Registry.register "dispatch", Space::Architect::CLI::Architect::Dispatch
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

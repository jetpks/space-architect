# frozen_string_literal: true

module SpaceArchitect
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
                  lanes = (s["lanes"] || []).map { |l| "#{l['name']}(#{l['repo']})" }.join(", ")
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

      module Worktree
        class Add < Dry::CLI::Command
          include GlobalOptions
          include Helpers

          desc "Create a worktree for a lane"
          argument :repo,      required: true, desc: "Repo name (under repos/)"
          argument :iteration, required: true, desc: "Iteration name"
          argument :lane,      required: true, desc: "Lane name"
          option   :base,      default: nil,   desc: "Base ref (default: HEAD of repo)"

          def call(repo:, iteration:, lane:, base: nil, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find) do |sp|
                mission = ArchitectMission.new(space: sp)
                result = mission.worktree_add(repo, iteration, lane, base: base)
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
    end
  end
end

SpaceArchitect::CLI::Registry.register "init",   SpaceArchitect::CLI::Architect::Init
SpaceArchitect::CLI::Registry.register "new",    SpaceArchitect::CLI::Architect::New
SpaceArchitect::CLI::Registry.register "status", SpaceArchitect::CLI::Architect::Status
SpaceArchitect::CLI::Registry.register "freeze", SpaceArchitect::CLI::Architect::Freeze
SpaceArchitect::CLI::Registry.register "verify", SpaceArchitect::CLI::Architect::Verify
SpaceArchitect::CLI::Registry.register "worktree" do |wt|
  wt.register "add",    SpaceArchitect::CLI::Architect::Worktree::Add
  wt.register "remove", SpaceArchitect::CLI::Architect::Worktree::Remove
  wt.register "list",   SpaceArchitect::CLI::Architect::Worktree::List
end

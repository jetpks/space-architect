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
            mission = ArchitectMission.new(space: store.find(space))
            path = mission.init!
            terminal.say "Mission ready: #{terminal.path(path)}"
            CLI.record_outcome(Outcome.new(exit_code: 0))
          end
        end
      end

      class New < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Scaffold the next slice file (artifacts/<NN>-<slice>.md)"
        argument :slice, required: true,  desc: "Slice name (kebab-case)"
        argument :space, required: false, desc: "Space identifier (default: $PWD)"

        def call(slice:, space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            mission = ArchitectMission.new(space: store.find(space))
            path = mission.new_slice!(slice)
            terminal.say "Slice scaffolded: #{terminal.path(path)}"
            CLI.record_outcome(Outcome.new(exit_code: 0))
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
            mission = ArchitectMission.new(space: store.find(space))
            info = mission.status
            block = info[:block]

            terminal.say "Mission status:  #{block['status'] || '(none)'}"
            terminal.say "Current slice:   #{block['current_slice'] || '(none)'}"

            slices = block["slices"] || []
            if slices.empty?
              terminal.say "Slices:          (none)"
            else
              rows = slices.map do |s|
                nn = s["ordinal"] ? format("%02d", s["ordinal"]) : "-"
                lanes = (s["lanes"] || []).map { |l| "#{l['name']}(#{l['repo']})" }.join(", ")
                [nn, s["name"], s["freeze_sha"]&.[](0, 8) || "-", lanes, s["verdict"] || "-"]
              end
              terminal.say terminal.table(%w[NN Slice FreezeSHA Lanes Verdict], rows)
            end

            unless info[:slice_files].empty?
              terminal.say "Slice files:     #{info[:slice_files].join(', ')}"
            end

            CLI.record_outcome(Outcome.new(exit_code: 0))
          end
        end
      end

      class Freeze < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Freeze gates for a slice"
        argument :slice, required: true, desc: "Slice name"
        argument :space, required: false, desc: "Space identifier (default: $PWD)"

        def call(slice:, space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            mission = ArchitectMission.new(space: store.find(space))
            sha = mission.freeze!(slice)
            terminal.say "Frozen #{slice} at #{sha}"
            CLI.record_outcome(Outcome.new(exit_code: 0))
          end
        end
      end

      class Verify < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Post-flight mechanical checks for a slice (reports only, no judgment)"
        argument :slice, required: true, desc: "Slice name"
        argument :space, required: false, desc: "Space identifier (default: $PWD)"

        def call(slice:, space: nil, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            mission = ArchitectMission.new(space: store.find(space))
            results = mission.verify(slice)

            if results.empty?
              terminal.say "No lanes recorded for slice '#{slice}'"
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
          argument :repo,  required: true, desc: "Repo name (under repos/)"
          argument :slice, required: true, desc: "Slice name"
          argument :lane,  required: true, desc: "Lane name"
          option   :base,  default: nil,   desc: "Base ref (default: HEAD of repo)"

          def call(repo:, slice:, lane:, base: nil, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              mission = ArchitectMission.new(space: store.find)
              result = mission.worktree_add(repo, slice, lane, base: base)
              terminal.say "Worktree: #{terminal.path(result[:worktree])}"
              terminal.say "Base SHA: #{result[:base_sha]}"
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end

        class Remove < Dry::CLI::Command
          include GlobalOptions
          include Helpers

          desc "Remove a lane worktree"
          argument :slice, required: true, desc: "Slice name"
          argument :lane,  required: true, desc: "Lane name"

          def call(slice:, lane:, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              mission = ArchitectMission.new(space: store.find)
              mission.worktree_remove(slice, lane)
              terminal.say "Removed worktree for #{slice}/#{lane}"
              CLI.record_outcome(Outcome.new(exit_code: 0))
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
              mission = ArchitectMission.new(space: store.find)
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

SpaceArchitect::CLI::Registry.register "architect" do |prefix|
  prefix.register "init",   SpaceArchitect::CLI::Architect::Init
  prefix.register "new",    SpaceArchitect::CLI::Architect::New
  prefix.register "status", SpaceArchitect::CLI::Architect::Status
  prefix.register "freeze", SpaceArchitect::CLI::Architect::Freeze
  prefix.register "verify", SpaceArchitect::CLI::Architect::Verify
  prefix.register "worktree" do |wt|
    wt.register "add",    SpaceArchitect::CLI::Architect::Worktree::Add
    wt.register "remove", SpaceArchitect::CLI::Architect::Worktree::Remove
    wt.register "list",   SpaceArchitect::CLI::Architect::Worktree::List
  end
end

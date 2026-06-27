# frozen_string_literal: true

module Space::Architect
  module CLI
    module Architect
      module Research
        class Dispatch < BaseCommand
          desc "Dispatch detached read-only research lanes (one per prompt file)"
          argument :prompts, required: true,
                             desc: "Prompt file(s) to dispatch (space-separated paths)"
          option :model,     default: nil, desc: "Model override (default: claude-sonnet-4-6)"
          option :max_turns, default: "40", desc: "Max turns per researcher"

          def call(prompts:, model: nil, max_turns: "40", **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find(opts[:space])) do |sp|
                paths = Array(prompts)
                supervisor = Space::Architect::Research::Supervisor.new(space: sp)
                kwargs = { max_turns: max_turns.to_i }
                kwargs[:model] = model if model
                runs = supervisor.dispatch(paths, **kwargs)
                runs.each do |run|
                  terminal.say "dispatched #{run.id} (pid #{run.pid}) → #{terminal.path(run.run_log_path)}"
                end
                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end

        class Status < BaseCommand
          desc "Show status of dispatched research runs"
          argument :space, required: false, desc: "Space identifier (default: $PWD)"

          def call(space: nil, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find(space)) do |sp|
                supervisor = Space::Architect::Research::Supervisor.new(space: sp)
                entries = supervisor.status
                if entries.empty?
                  terminal.say "No research runs registered"
                else
                  rows = entries.map do |e|
                    run = e[:run]
                    [run.id, run.pid.to_s, e[:state].to_s, run.model, e[:tail].last.to_s.slice(0, 60)]
                  end
                  terminal.say terminal.table(%w[ID PID State Model LastLine], rows)
                end
                CLI.record_outcome(Outcome.new(exit_code: 0))
              end
            end
          end
        end

        class Wait < BaseCommand
          desc "Wait for all dispatched research runs to complete"
          argument :space,    required: false, desc: "Space identifier (default: $PWD)"
          option   :quiet,    type: :boolean, default: false,
                              desc: "L0: suppress all output; exit status only"
          option   :level,    type: :integer, default: 1,
                              desc: "Verbosity level: 1=lifecycle 2=+text 3=+tools 4=+io"
          option   :thinking, type: :boolean, default: false,
                              desc: "Show assistant thinking blocks"
          option   :jsonl,    type: :boolean, default: false,
                              desc: "Emit raw lane-tagged JSONL (mutually exclusive with level/quiet)"

          def call(space: nil, quiet: false, level: 1, thinking: false, jsonl: false, **opts)
            setup_terminal(**opts.slice(:color, :colors))
            handle_errors do
              render(store.find(space)) do |sp|
                supervisor = Space::Architect::Research::Supervisor.new(space: sp)
                result = supervisor.wait(
                  quiet:   quiet,
                  level:   level.to_i,
                  thinking: thinking,
                  jsonl:   jsonl
                )
                CLI.record_outcome(Outcome.new(exit_code: result == :ok ? 0 : 1))
              end
            end
          end
        end
      end
    end
  end
end

Space::Architect::CLI::Registry.register "research" do |r|
  r.register "dispatch", Space::Architect::CLI::Architect::Research::Dispatch
  r.register "status",   Space::Architect::CLI::Architect::Research::Status
  r.register "wait",     Space::Architect::CLI::Architect::Research::Wait
end

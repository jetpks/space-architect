# frozen_string_literal: true

module SpaceArchitect
  module CLI
    class Status < Dry::CLI::Command
      include GlobalOptions
      include Helpers

      desc "Set a space status: active, paused, done, archived"
      argument :rest, type: :array, required: false, desc: "[SPACE] STATUS"

      def call(rest: [], **opts)
        setup_terminal(**opts.slice(:color, :colors))
        handle_errors do
          identifier, status_value = parse_status_args(Array(rest))
          render(store.find(identifier)) do |space|
            space.update_status(status_value)
            terminal.success "#{space.id} is #{space.status}"
            CLI.record_outcome(Outcome.new(exit_code: 0))
          end
        end
      end

      private

      def parse_status_args(args)
        case args.length
        when 1
          [nil, args.first]
        when 2
          args
        else
          raise SpaceArchitect::Error, "Usage: space status [SPACE] STATUS"
        end
      end
    end
  end
end


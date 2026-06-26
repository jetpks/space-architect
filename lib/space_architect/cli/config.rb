# frozen_string_literal: true

module SpaceArchitect
  module CLI
    module Config
      class Show < BaseCommand
        desc "Show current config"

        def call(**opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            rows = SpaceArchitect::Config::EDITABLE_KEYS.map do |key|
              value = project_config.data[key]
              [key, value.nil? ? "" : value.to_s]
            end
            terminal.say terminal.table(%w[Key Value], rows)
            CLI.record_outcome(Outcome.new(exit_code: 0))
          end
        end
      end

      class ConfigPath < BaseCommand
        desc "Print the config file path"

        def call(**opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            terminal.say terminal.path(project_config.path)
            CLI.record_outcome(Outcome.new(exit_code: 0))
          end
        end
      end

      class Set < BaseCommand
        desc "Set a config key"
        argument :key, required: true, desc: "Config key"
        argument :value, required: true, desc: "Config value"

        def call(key:, value:, **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            project_config.set(key, value)
            stored = project_config.data[key]
            terminal.success "Set #{key}=#{stored.nil? ? '' : stored.to_s}"
            CLI.record_outcome(Outcome.new(exit_code: 0))
          end
        end
      end
    end
  end
end


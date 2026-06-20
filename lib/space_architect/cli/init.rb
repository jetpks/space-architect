# frozen_string_literal: true

module SpaceArchitect
  module CLI
    class Init < Dry::CLI::Command
      include GlobalOptions
      include Helpers

      desc "Create default XDG config and state files"
      option :force, type: :boolean, default: false, desc: "Overwrite existing config and state files"

      def call(force: false, **opts)
        setup_terminal(**opts.slice(:color, :colors))
        handle_errors do
          if force
            @project_config = SpaceArchitect::Config.new
            @state = SpaceArchitect::State.new
            project_config.save
            state.save
          else
            project_config.ensure_exists!
            state.ensure_exists!
          end

          FileUtils.mkdir_p(project_config.spaces_dir)
          terminal.success "Config: #{terminal.path(project_config.path)}"
          terminal.success "State: #{terminal.path(state.path)}"
          terminal.success "Spaces: #{terminal.path(project_config.spaces_dir)}"
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end
    end
  end
end


# frozen_string_literal: true

module Space::Core::CLI
module Shell
  class ShellInit < BaseCommand
    desc "Print shell integration script"
    argument :shell_name, required: true, desc: "Shell name (e.g. fish)"

    def call(shell_name:, **opts)
      setup_terminal(**opts.slice(:color, :colors))
      handle_errors do
        terminal.say Space::Core::ShellIntegration.for(shell_name)
        CLI.record_outcome(Outcome.new(exit_code: 0))
      end
    end
  end

  class Fish < BaseCommand
    desc "Manage fish shell integration: install, uninstall, path"
    argument :subcommand, required: false, desc: "install, uninstall, or path (default: install)"
    option :force, type: :boolean, default: false, desc: "Overwrite or remove existing shell files"

    def call(subcommand: "install", force: false, **opts)
      setup_terminal(**opts.slice(:color, :colors))
      handle_errors do
        case subcommand
        when "install"
          result = Space::Core::ShellIntegration.install("fish", env: project_config.env, force: force)
          terminal.success fish_install_message(result.fetch(:action), result.fetch(:path))
          terminal.success fish_completions_install_message(result.fetch(:completions_action), result.fetch(:completions_path))
          terminal.say "Restart fish to load the integration in this terminal: exec fish"
        when "uninstall"
          result = Space::Core::ShellIntegration.uninstall("fish", env: project_config.env, force: force)
          terminal.success fish_uninstall_message(result.fetch(:action), result.fetch(:path))
          terminal.success fish_completions_uninstall_message(result.fetch(:completions_action), result.fetch(:completions_path))
        when "path"
          terminal.say "Function:    #{terminal.path(Space::Core::ShellIntegration.path_for('fish', env: project_config.env))}"
          terminal.say "Completions: #{terminal.path(Space::Core::ShellIntegration.completions_path_for('fish', env: project_config.env))}"
        else
          err.puts "Usage: space shell fish [install|uninstall|path]"
          CLI.record_outcome(Outcome.new(exit_code: 1))
          next
        end
        CLI.record_outcome(Outcome.new(exit_code: 0))
      end
    end

    private

    def fish_install_message(action, path)
      case action
      when :unchanged then "Fish integration already installed: #{terminal.path(path)}"
      when :updated   then "Updated fish integration: #{terminal.path(path)}"
      else                 "Installed fish integration: #{terminal.path(path)}"
      end
    end

    def fish_uninstall_message(action, path)
      case action
      when :missing then "Fish integration was not installed: #{terminal.path(path)}"
      else               "Removed fish integration: #{terminal.path(path)}"
      end
    end

    def fish_completions_install_message(action, path)
      case action
      when :unchanged then "Fish completions already installed: #{terminal.path(path)}"
      when :updated   then "Updated fish completions: #{terminal.path(path)}"
      else                 "Installed fish completions: #{terminal.path(path)}"
      end
    end

    def fish_completions_uninstall_message(action, path)
      case action
      when :missing then "Fish completions were not installed: #{terminal.path(path)}"
      else               "Removed fish completions: #{terminal.path(path)}"
      end
    end
  end

  class Complete < BaseCommand
    desc "Print completion candidates"
    argument :kind, required: true, desc: "Completion kind"
    argument :extra, type: :array, required: false, desc: "Extra args for completion"

    def call(kind:, extra: [], **opts)
      setup_terminal(**opts.slice(:color, :colors))
      handle_errors do
        completion_candidates(kind, Array(extra)).each { |c| terminal.say c }
        CLI.record_outcome(Outcome.new(exit_code: 0))
      end
    end

    private

    def completion_candidates(kind, args)
      case kind
      when "spaces"          then store.list.map { |space| "#{space.id}\t#{space.title}" }
      when "statuses"        then Space::Core::Space::VALID_STATUSES
      when "config-keys"     then Space::Core::Config::EDITABLE_KEYS
      when "config-values"   then completion_values_for_config_key(args.first)
      when "shells"          then ["fish"]
      when "color-modes"     then %w[auto always never]
      when "repo-subcommands"   then %w[add list ls resolve]
      when "config-subcommands" then %w[show path set]
      when "fish-subcommands"   then %w[install uninstall path]
      else
        raise Space::Core::Error, "Usage: space shell complete #{completion_kinds.join('|')}"
      end
    end

    def completion_values_for_config_key(key)
      case key
      when "git_clone_protocol" then Space::Core::Config::VALID_GIT_CLONE_PROTOCOLS
      when "default_provider"   then %w[github.com gitlab.com]
      else []
      end
    end

    def completion_kinds
      %w[spaces statuses config-keys config-values shells color-modes repo-subcommands config-subcommands fish-subcommands]
    end
  end
end
end

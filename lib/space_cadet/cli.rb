# frozen_string_literal: true

require "thor"

module SpaceCadet
  class CLI < Thor
    package_name "space"

    def self.exit_on_failure?
      true
    end

    def self.start(given_args = ARGV, config = {})
      super(normalize_global_color_options(given_args), config)
    end

    def self.normalize_global_color_options(given_args)
      args = given_args.dup
      extracted = []
      index = 0

      while index < args.length
        arg = args[index]
        break if arg == "--"

        if %w[--color --colors].include?(arg)
          extracted << arg
          extracted << args[index + 1] if args[index + 1] && !args[index + 1].start_with?("-")
          args.slice!(index, extracted.last == arg ? 1 : 2)
        elsif arg.start_with?("--color=", "--colors=")
          extracted << arg
          args.delete_at(index)
        else
          index += 1
        end
      end

      return args if extracted.empty?

      command_index = args.index { |arg| !arg.start_with?("-") }
      return args + extracted unless command_index

      args.insert(command_index + 1, *extracted)
    end

    map "ls" => :list
    map "repos" => :repo
    map "shell" => :shell_command

    class_option :color,
                 type: :string,
                 default: "auto",
                 desc: "Color output: auto, always, never"
    class_option :colors,
                 type: :string,
                 desc: "Alias for --color"

    desc "init", "Create default XDG config and state files"
    option :force, type: :boolean, default: false, desc: "Overwrite existing config and state files"
    def init
      handle_errors do
        if options[:force]
          @config = Config.new
          @state = State.new
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
      end
    end

    desc "new TITLE", "Create a new project space"
    option :repo,
           aliases: "-r",
           type: :string,
           repeatable: true,
           banner: "REPO",
           desc: "Clone a repo into the new space; repeatable"
    option :git,
           type: :boolean,
           default: true,
           desc: "Initialize the space as a Git repository (use --no-git to skip)"
    def new(title)
      handle_errors do
        space = store.create(title, git: options[:git])
        terminal.success "Created #{space.id}"

        new_repo_specs.each do |repo_spec|
          terminal.say "Queued #{repo_spec}"
        end

        unless new_repo_specs.empty?
          progress = RepoProgress.new(new_repo_specs.length)
          results = terminal.with_spinner(-> { progress.message }) do
            store.add_repos_to(space, new_repo_specs, reporter: progress)
          end

          results.each do |result|
            terminal.success "Added #{result.fetch(:repo).fetch('full_name')}"
            terminal.say terminal.path(result.fetch(:path))
          end
        end

        terminal.say terminal.path(space.path)
      end
    end

    desc "list", "List spaces"
    def list
      handle_errors do
        spaces = store.list
        if spaces.empty?
          terminal.say "No spaces found in #{terminal.path(project_config.spaces_dir)}"
          next
        end

        rows = spaces.map do |space|
          [space.status, display_date(space), space.title, terminal.path(space.path)]
        end
        terminal.say terminal.table(%w[Status Date Title Path], rows)
      end
    end

    desc "show [SPACE]", "Show metadata for a space or the current space"
    def show(identifier = nil)
      handle_errors do
        space = store.find(identifier)
        terminal.say "ID:         #{space.id}"
        terminal.say "Title:      #{space.title}"
        terminal.say "Status:     #{space.status}"
        terminal.say "Path:       #{terminal.path(space.path)}"
        terminal.say "Created:    #{space.data['created_at']}"
        terminal.say "Updated:    #{space.data['updated_at']}"
      end
    end

    desc "path [SPACE]", "Print the path for a space or the current space"
    def path(identifier = nil)
      handle_errors do
        terminal.say terminal.path(store.path_for(identifier))
      end
    end

    desc "use SPACE", "Remember a space in recent state and print its path"
    def use(identifier)
      handle_errors do
        space = store.use(identifier)
        terminal.success "Recent space: #{space.id}"
        terminal.say terminal.path(space.path)
      end
    end

    desc "current", "Show the current space"
    def current
      handle_errors do
        space = store.find
        terminal.say "#{space.id}"
        terminal.say terminal.path(space.path)
      end
    end

    desc "status [SPACE] STATUS", "Set a space status: active, paused, done, archived"
    def status(*args)
      handle_errors do
        identifier, status_value = status_args(args)
        space = store.find(identifier)
        space.update_status(status_value)
        terminal.success "#{space.id} is #{space.status}"
      end
    end

    desc "config [SUBCOMMAND]", "Show or update config: show, set KEY VALUE"
    def config(*args)
      handle_errors do
        case args.shift || "show"
        when "show"
          terminal.say terminal.table(%w[Key Value], config_rows)
        when "path"
          terminal.say terminal.path(project_config.path)
        when "set"
          key, value = config_set_args(args)
          project_config.set(key, value)
          terminal.success "Set #{key}=#{format_config_value(project_config.data[key])}"
        else
          raise Thor::Error, "Usage: space config [show|path|set KEY VALUE]"
        end
      end
    end

    desc "repo SUBCOMMAND", "Manage repos in the current space: add, list, resolve"
    def repo(*args)
      handle_errors do
        case args.shift
        when "add"
          specs = repo_args(args, "Usage: space repo add REPO [REPO...]")
          progress = RepoProgress.new(specs.length)
          results = terminal.with_spinner(-> { progress.message }) do
            store.add_repos(specs, reporter: progress)
          end

          results.each do |result|
            terminal.success "Added #{result.fetch(:repo).fetch('full_name')}"
            terminal.say terminal.path(result.fetch(:path))
          end
        when "list", "ls"
          repos = store.repos
          if repos.empty?
            terminal.say "No repos found in #{store.find.id}"
            next
          end

          rows = repos.map { |repo| [repo.fetch("full_name", repo["name"]), repo.fetch("path", "")] }
          terminal.say terminal.table(["Repo", "Path"], rows)
        when "resolve"
          specs = repo_args(args, "Usage: space repo resolve REPO [REPO...]")
          references = specs.map { |spec| RepoResolver.new(project_config).resolve(spec) }
          terminal.say terminal.table(["Repo", "Clone URL"], references.map { |reference| [reference.full_name, reference.clone_url] })
        else
          raise Thor::Error, "Usage: space repo [add|list|resolve] REPO [REPO...]"
        end
      end
    end

    desc "shell SUBCOMMAND", "Manage shell integration: init, fish, complete"
    option :force, type: :boolean, default: false, desc: "Overwrite or remove existing shell files"
    def shell_command(*args)
      handle_errors do
        case args.shift
        when "init"
          shell = args.shift || raise(Thor::Error, "Usage: space shell init SHELL")
          raise Thor::Error, "Usage: space shell init SHELL" unless args.empty?

          terminal.say ShellIntegration.for(shell)
        when "fish"
          shell_fish(args)
        when "complete"
          kind = args.shift || raise(Thor::Error, "Usage: space shell complete KIND [ARGS...]")
          completion_candidates(kind, args).each do |candidate|
            terminal.say candidate
          end
        else
          raise Thor::Error, "Usage: space shell [init|fish|complete]"
        end
      end
    end

    class RepoProgress
      def initialize(total)
        @total = total
        @statuses = {}
      end

      def start(addition)
        source = addition[:evergreen_source]
        @statuses[addition.fetch(:reference).full_name] = source&.directory? ? :copying : :cloning
      end

      def trust(addition)
        @statuses[addition.fetch(:reference).full_name] = :trusting
      end

      def finish(addition)
        @statuses[addition.fetch(:reference).full_name] = :done
      end

      def fail(addition)
        @statuses[addition.fetch(:reference).full_name] = :failed
      end

      def message
        done = @statuses.count { |_repo, status| status == :done }
        failed = @statuses.count { |_repo, status| status == :failed }
        copying = @statuses.select { |_repo, status| status == :copying }.keys
        cloning = @statuses.select { |_repo, status| status == :cloning }.keys
        trusting = @statuses.select { |_repo, status| status == :trusting }.keys

        if @total == 1
          copying_repo = copying.first
          cloning_repo = cloning.first
          trusting_repo = trusting.first
          return "Copying #{copying_repo}" if copying_repo
          return "Cloning #{cloning_repo}" if cloning_repo
          return "Trusting #{trusting_repo}" if trusting_repo
          return "Fetch failed" if failed.positive?

          "Preparing repos"
        else
          active = []
          active << "copying #{copying.join(', ')}" unless copying.empty?
          active << "cloning #{cloning.join(', ')}" unless cloning.empty?
          active << "trusting #{trusting.join(', ')}" unless trusting.empty?
          suffix = active.empty? ? nil : ": #{active.join('; ')}"
          failed_text = failed.positive? ? ", #{failed} failed" : ""
          "Fetching repos #{done}/#{@total}#{failed_text}#{suffix}"
        end
      end
    end

    private

    def project_config
      @config ||= Config.load
    end

    def state
      @state ||= State.load
    end

    def store
      @store ||= SpaceStore.new(config: project_config, state:)
    end

    def terminal
      @terminal ||= Terminal.new(config: project_config, color_mode: options[:colors] || options[:color] || "auto")
    end

    def new_repo_specs
      Array(options[:repo]).compact
    end

    def status_args(args)
      case args.length
      when 1
        [nil, args.first]
      when 2
        args
      else
        raise Thor::Error, "Usage: space status [SPACE] STATUS"
      end
    end

    def config_rows
      Config::EDITABLE_KEYS.map do |key|
        [key, format_config_value(project_config.data[key])]
      end
    end

    def config_set_args(args)
      unless args.length == 2
        raise Thor::Error, "Usage: space config set KEY VALUE"
      end

      args
    end

    def format_config_value(value)
      value.nil? ? "" : value.to_s
    end

    def repo_args(args, usage)
      raise Thor::Error, usage if args.empty?

      args
    end

    def shell_fish(args)
      subcommand = args.shift || "install"
      raise Thor::Error, "Usage: space shell fish [install|uninstall|path]" unless args.empty?

      case subcommand
      when "install"
        result = ShellIntegration.install("fish", env: project_config.env, force: options[:force])
        terminal.success fish_install_message(result.fetch(:action), result.fetch(:path))
        terminal.success fish_completions_install_message(result.fetch(:completions_action), result.fetch(:completions_path))
        terminal.say "Restart fish to load the integration in this terminal: exec fish"
      when "uninstall"
        result = ShellIntegration.uninstall("fish", env: project_config.env, force: options[:force])
        terminal.success fish_uninstall_message(result.fetch(:action), result.fetch(:path))
        terminal.success fish_completions_uninstall_message(result.fetch(:completions_action), result.fetch(:completions_path))
      when "path"
        terminal.say "Function:    #{terminal.path(ShellIntegration.path_for('fish', env: project_config.env))}"
        terminal.say "Completions: #{terminal.path(ShellIntegration.completions_path_for('fish', env: project_config.env))}"
      else
        raise Thor::Error, "Usage: space shell fish [install|uninstall|path]"
      end
    end

    def fish_install_message(action, path)
      case action
      when :unchanged
        "Fish integration already installed: #{terminal.path(path)}"
      when :updated
        "Updated fish integration: #{terminal.path(path)}"
      else
        "Installed fish integration: #{terminal.path(path)}"
      end
    end

    def fish_uninstall_message(action, path)
      case action
      when :missing
        "Fish integration was not installed: #{terminal.path(path)}"
      else
        "Removed fish integration: #{terminal.path(path)}"
      end
    end

    def fish_completions_install_message(action, path)
      case action
      when :unchanged
        "Fish completions already installed: #{terminal.path(path)}"
      when :updated
        "Updated fish completions: #{terminal.path(path)}"
      else
        "Installed fish completions: #{terminal.path(path)}"
      end
    end

    def fish_completions_uninstall_message(action, path)
      case action
      when :missing
        "Fish completions were not installed: #{terminal.path(path)}"
      else
        "Removed fish completions: #{terminal.path(path)}"
      end
    end

    def completion_candidates(kind, args)
      case kind
      when "spaces"
        store.list.map { |space| "#{space.id}\t#{space.title}" }
      when "statuses"
        Space::VALID_STATUSES
      when "config-keys"
        Config::EDITABLE_KEYS
      when "config-values"
        completion_values_for_config_key(args.first)
      when "shells"
        ["fish"]
      when "color-modes"
        %w[auto always never]
      when "repo-subcommands"
        %w[add list ls resolve]
      when "config-subcommands"
        %w[show path set]
      when "fish-subcommands"
        %w[install uninstall path]
      else
        raise Thor::Error, "Usage: space shell complete #{completion_kinds.join('|')}"
      end
    end

    def completion_values_for_config_key(key)
      case key
      when "git_clone_protocol"
        Config::VALID_GIT_CLONE_PROTOCOLS
      when "default_provider"
        %w[github.com gitlab.com]
      else
        []
      end
    end

    def completion_kinds
      %w[
        spaces
        statuses
        config-keys
        config-values
        shells
        color-modes
        repo-subcommands
        config-subcommands
        fish-subcommands
      ]
    end

    def display_date(space)
      id_date = space.id.match(/\A(\d{4})(\d{2})(\d{2})/)
      return "#{id_date[1]}-#{id_date[2]}-#{id_date[3]}" if id_date

      space.data["created_at"].to_s[0, 10]
    end

    def handle_errors
      yield
    rescue SpaceCadet::Error => e
      raise Thor::Error, e.message
    end
  end
end

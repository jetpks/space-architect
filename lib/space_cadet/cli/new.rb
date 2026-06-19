# frozen_string_literal: true

module SpaceCadet
  module CLI
    class New < Dry::CLI::Command
      include GlobalOptions
      include Helpers

      desc "Create a new project space"
      argument :title, required: true, desc: "Space title"
      argument :repos, type: :array, required: false, desc: "Repo refs to clone"
      option :git, type: :boolean, default: true, desc: "Initialize the space as a Git repository (use --no-git to skip)"

      def call(title:, repos: [], git: true, **opts)
        setup_terminal(**opts.slice(:color, :colors))
        handle_errors do
          space = store.create(title, git: git)
          terminal.success "Created #{space.id}"

          repo_specs = Array(repos).compact
          repo_specs.each { |spec| terminal.say "Queued #{spec}" }

          unless repo_specs.empty?
            progress = RepoProgress.new(repo_specs.length)
            results = terminal.with_spinner(-> { progress.message }) do
              store.add_repos_to(space, repo_specs, reporter: progress)
            end

            results.each do |result|
              terminal.success "Added #{result.fetch(:repo).fetch('full_name')}"
              terminal.say terminal.path(result.fetch(:path))
            end
          end

          terminal.say terminal.path(space.path)
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end
    end
  end
end

SpaceCadet::CLI::Registry.register "new", SpaceCadet::CLI::New

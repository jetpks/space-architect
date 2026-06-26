# frozen_string_literal: true

module SpaceArchitect
  module CLI
    class New < BaseCommand
      desc "Create a new project space"
      argument :title, required: true, desc: "Space title"
      option :repo, type: :array, aliases: ["-r"], desc: "Repo ref to clone (repeatable: pass -r once per repo)"
      option :git, type: :boolean, default: true, desc: "Initialize the space as a Git repository (use --no-git to skip)"
      example "\"My Space\" -r org/repo -r example-tools/alpha   # clone two repos into the space"

      def call(title:, repo: [], git: true, **opts)
        setup_terminal(**opts.slice(:color, :colors))
        result = store.create(title, git: git).bind do |space|
          terminal.success "Created #{space.id}"

          repo_specs = Array(repo).compact
          repo_specs.each { |spec| terminal.say "Queued #{spec}" }

          next Success(space) if repo_specs.empty?

          progress = RepoProgress.new(repo_specs.length)
          terminal.with_spinner(-> { progress.message }) do
            store.add_repos_to(space, repo_specs, reporter: progress)
          end.fmap do |results|
            results.each do |r|
              terminal.success "Added #{r.fetch(:repo).fetch('full_name')}"
              terminal.say terminal.path(r.fetch(:path))
            end
            space
          end
        end
        render(result) do |space|
          terminal.say terminal.path(space.path)
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end
    end
  end
end


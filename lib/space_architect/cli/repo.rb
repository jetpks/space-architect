# frozen_string_literal: true

module SpaceArchitect
  module CLI
    module Repo
      class Add < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Clone repos into the current space"
        argument :repos, type: :array, required: false, desc: "REPO [REPO...]"

        def call(repos: [], **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            specs = Array(repos).compact
            if specs.empty?
              terminal.error("Usage: space repo add REPO [REPO...]")
              CLI.record_outcome(Outcome.new(exit_code: 1))
              next
            end

            progress = RepoProgress.new(specs.length)
            add_result = terminal.with_spinner(-> { progress.message }) do
              store.add_repos(specs, reporter: progress)
            end
            render(add_result) do |results|
              results.each do |result|
                terminal.success "Added #{result.fetch(:repo).fetch('full_name')}"
                terminal.say terminal.path(result.fetch(:path))
              end
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class RepoList < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "List repos in the current space"

        def call(**opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            render(store.repos) do |repos|
              if repos.empty?
                id = store.find.fmap(&:id).value_or("(unknown space)")
                terminal.say "No repos found in #{id}"
                next
              end

              rows = repos.map { |repo| [repo.fetch("full_name", repo["name"]), repo.fetch("path", "")] }
              terminal.say terminal.table(["Repo", "Path"], rows)
              CLI.record_outcome(Outcome.new(exit_code: 0))
            end
          end
        end
      end

      class Resolve < Dry::CLI::Command
        include GlobalOptions
        include Helpers

        desc "Resolve repo refs without cloning"
        argument :repos, type: :array, required: false, desc: "REPO [REPO...]"

        def call(repos: [], **opts)
          setup_terminal(**opts.slice(:color, :colors))
          handle_errors do
            specs = Array(repos).compact
            if specs.empty?
              terminal.error("Usage: space repo resolve REPO [REPO...]")
              CLI.record_outcome(Outcome.new(exit_code: 1))
              next
            end

            references = specs.map { |spec| RepoResolver.new(project_config).resolve(spec) }
            terminal.say terminal.table(["Repo", "Clone URL"], references.map { |ref| [ref.full_name, ref.clone_url] })
            CLI.record_outcome(Outcome.new(exit_code: 0))
          end
        end
      end
    end
  end
end

SpaceArchitect::CLI::Registry.register "repo" do |prefix|
  prefix.register "add",     SpaceArchitect::CLI::Repo::Add
  prefix.register "list",    SpaceArchitect::CLI::Repo::RepoList
  prefix.register "ls",      SpaceArchitect::CLI::Repo::RepoList
  prefix.register "resolve", SpaceArchitect::CLI::Repo::Resolve
end

SpaceArchitect::CLI::Registry.register "repos" do |prefix|
  prefix.register "add",     SpaceArchitect::CLI::Repo::Add
  prefix.register "list",    SpaceArchitect::CLI::Repo::RepoList
  prefix.register "ls",      SpaceArchitect::CLI::Repo::RepoList
  prefix.register "resolve", SpaceArchitect::CLI::Repo::Resolve
end

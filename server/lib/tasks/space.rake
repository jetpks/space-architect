# frozen_string_literal: true

namespace :space do
  desc "Import a space directory: rake space:import[/path/to/space]"
  task :import, [:path] => :environment do |_, args|
    require "space/server/space_importer"
    path = args[:path]
    abort "Usage: rake space:import[/path/to/space]" if path.nil? || path.empty?

    user_id = ENV.fetch("SPACE_IMPORT_USER_ID") do
      Space::Server::App["db.gateway"].connection[:users].order(:id).first&.dig(:id)
    end
    abort "No user found. Set SPACE_IMPORT_USER_ID env var." unless user_id

    users_repo = Space::Server::App["repos.users_repo"]
    user       = users_repo.by_pk(Integer(user_id))
    abort "User #{user_id} not found." unless user

    importer = Space::Server::SpaceImporter.new(
      spaces_repo:        Space::Server::App["repos.spaces_repo"],
      iterations_repo:    Space::Server::App["repos.iterations_repo"],
      artifacts_repo:     Space::Server::App["repos.artifacts_repo"],
      runs_repo:          Space::Server::App["repos.runs_repo"],
      conversations_repo: Space::Server::App["repos.conversations_repo"],
      messages_repo:      Space::Server::App["repos.messages_repo"]
    )

    space = importer.import!(path, user: user)
    puts "Imported space: #{space.slug} (id=#{space.id})"
  end
end

# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Spaces
        class Index < Space::Server::Action
          include Space::Server::Deps[
            "repos.spaces_repo",
            "repos.iterations_repo",
            "repos.runs_repo"
          ]

          def handle(req, res)
            user   = current_user(req)
            spaces = spaces_repo.list_visible_to(user)

            space_list = spaces.map do |space|
              {
                id:               space.id,
                slug:             space.slug,
                title:            space.title,
                status:           space.status.to_s,
                iterations_count: iterations_repo.count_for_space(space.id),
                runs_count:       runs_repo.count_for_space(space.id),
                imported_at:      space.imported_at&.iso8601(6),
                git_utc_offset:   space.git_utc_offset
              }
            end

            render_inertia(req, res, "Spaces/Index", props: { spaces: space_list })
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module Space
  module Server
    module Repos
      class RunsRepo < Space::Server::DB::Repo
        def by_pk(id)
          runs.by_pk(id).one
        end

        def by_user(user_id)
          runs.where(user_id: user_id).to_a
        end

        def create(attrs)
          runs.command(:create).call(attrs)
        end

        def update(id, attrs)
          runs.by_pk(id).command(:update).call(attrs)
        end

        def delete(id)
          runs.by_pk(id).command(:delete).call
        end

        # Anonymous → published only. Signed-in → published or owned.
        # Simplified: no share grants for runs (those are added in a later iteration).
        def visible_to(user)
          if user.nil?
            return runs.where(published: true).to_a
          end

          expr = Sequel.expr(published: true) | Sequel.expr(user_id: user.id)
          runs.where(expr).to_a
        end

        PAGE_SIZE = 50

        # Index scope: published ∪ owned-by-user, newest first, paged (page size
        # 50). Anonymous (user nil) → published only. Fetches PAGE_SIZE + 1 rows
        # to detect has_more without a COUNT query.
        def list_visible_to(user, page: 1)
          expr = user.nil? ? { published: true } : Sequel.expr(published: true) | Sequel.expr(user_id: user.id)
          rows = runs.where(expr)
                     .order(Sequel.desc(:created_at))
                     .limit(PAGE_SIZE + 1)
                     .offset((page - 1) * PAGE_SIZE)
                     .to_a
          { rows: rows.first(PAGE_SIZE), has_more: rows.size > PAGE_SIZE }
        end

        def for_show(id)
          runs.by_pk(id).combine(:user).one
        end

        def for_space(space_id)
          runs.where(space_id: space_id).to_a
        end

        def count_for_space(space_id)
          runs.dataset.where(space_id: space_id).count
        end

        # Find a builder run by its natural key within a space.
        def find_builder_run(space_id, iteration_id, lane)
          runs.where(space_id: space_id, iteration_id: iteration_id, lane: lane)
              .order(Sequel.desc(:created_at)).to_a.first
        end

        # Find an architect session run by its natural key (space_id + session_id).
        def find_architect_run(space_id, session_id)
          runs.where(space_id: space_id, role: "architect", session_id: session_id)
              .order(Sequel.desc(:created_at)).to_a.first
        end
      end
    end
  end
end

# frozen_string_literal: true

module Space
  module Server
    module Repos
      class JobsRepo < Space::Server::DB::Repo
        def by_pk(id)
          jobs.by_pk(id).one
        end

        def create(attrs)
          jobs.command(:create).call(attrs)
        end

        def update(id, attrs)
          jobs.by_pk(id).command(:update).call(attrs)
        end

        def delete(id)
          jobs.by_pk(id).command(:delete).call
        end

        def by_user(user_id)
          jobs.where(user_id: user_id).to_a
        end
      end
    end
  end
end

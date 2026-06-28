# frozen_string_literal: true

module Space
  module Server
    module Repos
      class UsersRepo < Space::Server::DB::Repo
        def by_github_uid(uid)
          users.where(github_uid: uid).one
        end

        def create(attrs)
          users.command(:create).call(attrs)
        end

        def update(id, attrs)
          users.by_pk(id).command(:update).call(attrs)
        end

        def delete(id)
          users.by_pk(id).command(:delete).call
        end

        def by_pk(id)
          users.by_pk(id).one
        end
      end
    end
  end
end

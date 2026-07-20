# frozen_string_literal: true

module Space
  module Server
    module Repos
      class ProfilesRepo < Space::Server::DB::Repo
        def by_pk(id)
          profiles.by_pk(id).one
        end

        def create(attrs)
          profiles.command(:create).call(attrs)
        end

        def delete(id)
          profiles.by_pk(id).command(:delete).call
        end

        def list_for_user(user_id)
          profiles.where(user_id: user_id).order(:name).to_a
        end
      end
    end
  end
end

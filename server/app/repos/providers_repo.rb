# frozen_string_literal: true

module Space
  module Server
    module Repos
      class ProvidersRepo < Space::Server::DB::Repo
        def by_id_for_user(id, user_id)
          providers.where(id: id, user_id: user_id).one
        end

        def create(attrs)
          providers.command(:create).call(attrs)
        end

        def delete(id)
          providers.by_pk(id).command(:delete).call
        end

        def list_for_user(user_id)
          providers.where(user_id: user_id).order(:name).to_a
        end
      end
    end
  end
end

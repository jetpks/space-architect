# frozen_string_literal: true

module Space
  module Server
    module Repos
      class SpacesRepo < Space::Server::DB::Repo
        def by_pk(id)
          spaces.by_pk(id).one
        end

        def update(id, attrs)
          spaces.by_pk(id).command(:update).call(attrs)
        end

        # Visibility: spaces are private — only the owner can see them.
        def list_visible_to(user)
          return [] if user.nil?
          spaces.where(user_id: user.id).order(Sequel.desc(:created_at)).to_a
        end

        # Find-or-create with update on match. Returns the upserted Space struct.
        def upsert_by_slug(user_id, slug, attrs)
          existing = spaces.where(user_id: user_id, slug: slug).to_a.first
          now = Time.now
          if existing
            spaces.by_pk(existing.id).command(:update).call(attrs.merge(updated_at: now))
            spaces.by_pk(existing.id).one
          else
            spaces.command(:create).call(
              attrs.merge(user_id: user_id, slug: slug, created_at: now, updated_at: now)
            )
          end
        end
      end
    end
  end
end

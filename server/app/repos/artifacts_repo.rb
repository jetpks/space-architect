# frozen_string_literal: true

module Space
  module Server
    module Repos
      class ArtifactsRepo < Space::Server::DB::Repo
        def for_space(space_id)
          artifacts.where(space_id: space_id).to_a
        end

        # Find-or-create with update on match. Returns the upserted Artifact struct.
        def upsert_by_path(space_id, path, attrs)
          existing = artifacts.where(space_id: space_id, path: path).to_a.first
          now = Time.now
          if existing
            artifacts.by_pk(existing.id).command(:update).call(attrs.merge(updated_at: now))
            artifacts.by_pk(existing.id).one
          else
            artifacts.command(:create).call(
              attrs.merge(space_id: space_id, path: path, created_at: now, updated_at: now)
            )
          end
        end
      end
    end
  end
end

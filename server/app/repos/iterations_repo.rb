# frozen_string_literal: true

module Space
  module Server
    module Repos
      class IterationsRepo < Space::Server::DB::Repo
        def for_space(space_id)
          iterations.where(space_id: space_id).order(:ordinal).to_a
        end

        def count_for_space(space_id)
          iterations.dataset.where(space_id: space_id).count
        end

        # Find-or-create with update on match. Returns the upserted Iteration struct.
        def upsert_by_ordinal(space_id, ordinal, attrs)
          existing = iterations.where(space_id: space_id, ordinal: ordinal).to_a.first
          now = Time.now
          if existing
            iterations.by_pk(existing.id).command(:update).call(attrs.merge(updated_at: now))
            iterations.by_pk(existing.id).one
          else
            iterations.command(:create).call(
              attrs.merge(space_id: space_id, ordinal: ordinal, created_at: now, updated_at: now)
            )
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Spaces
        class Show < Space::Server::Action
          CANONICAL_SECTIONS = [
            "Grounds", "Specification", "Acceptance Criteria",
            "Builder Prompt", "Builder Report", "Verdict"
          ].freeze

          include Space::Server::Deps[
            "repos.spaces_repo",
            "repos.iterations_repo",
            "repos.artifacts_repo",
            "repos.runs_repo",
            "repos.conversations_repo"
          ]

          def handle(req, res)
            id    = req.params[:id].to_i
            space = spaces_repo.by_pk(id)
            halt_not_found(res) unless space

            user = current_user(req)
            unless space.visible_to?(user)
              alert = user ? "Not found." : "Please sign in to view this space."
              redirect_with_flash(res, "/", alert: alert)
            end

            iterations = iterations_repo.for_space(space.id)
            artifacts  = artifacts_repo.for_space(space.id)
            runs       = runs_repo.for_space(space.id)

            iter_artifacts = artifacts.group_by(&:iteration_id)
            iter_runs      = runs.select { |r| r.iteration_id }.group_by(&:iteration_id)

            iterations_props = iterations.map do |iter|
              {
                id:                     iter.id,
                ordinal:                iter.ordinal,
                name:                   iter.name,
                freeze_sha:             iter.freeze_sha,
                verdict:                iter.verdict,
                created_at:             iter.created_at.iso8601(6),
                occurred_at:            iter.occurred_at&.iso8601(6),
                occurred_at_utc_offset: iter.occurred_at_utc_offset,
                decisions:              decisions_for(iter, iter_artifacts),
                artifacts:              Array(iter_artifacts[iter.id]).map { |a| artifact_props(a) },
                runs:                   Array(iter_runs[iter.id]).map { |r| run_props(r) }
              }
            end

            orphan_runs     = runs.select { |r| r.iteration_id.nil? }
            architect_runs  = orphan_runs
              .select { |r| r.role.to_s == "architect" }
              .sort_by(&:created_at)
              .map { |r| architect_run_props(r, user) }
            unassigned_runs = orphan_runs
              .reject { |r| r.role.to_s == "architect" }
              .map { |r| run_props(r) }

            other_artifacts = artifacts.select { |a| a.iteration_id.nil? }
                                       .map { |a| artifact_props(a) }

            render_inertia(req, res, "Spaces/Show", props: {
              space: {
                id:             space.id,
                slug:           space.slug,
                title:          space.title,
                status:         space.status.to_s,
                repos:          Array(space.repos),
                git_utc_offset: space.git_utc_offset
              },
              iterations:      iterations_props,
              architect_runs:  architect_runs,
              unassigned_runs: unassigned_runs,
              other_artifacts: other_artifacts
            })
          end

          private

          def decisions_for(iter, iter_artifacts)
            iter_art = Array(iter_artifacts[iter.id]).find { |a| a.kind == "iteration" }
            return [] unless iter_art

            sections = Space::Server::SectionParser.split_canonical(iter_art.raw, CANONICAL_SECTIONS)
            CANONICAL_SECTIONS.filter_map do |name|
              next unless sections.key?(name)
              { name: name, body: sections[name] }
            end
          end

          def artifact_props(a)
            { id: a.id, kind: a.kind, path: a.path, title: a.title }
          end

          def run_props(r)
            { id: r.id, lane: r.lane, role: r.role, status: r.status.to_s,
              conversation_id: r.conversation_id, created_at: r.created_at.iso8601(6),
              harness: r.harness, model: r.model }
          end

          def architect_run_props(r, user)
            conversation = r.conversation_id &&
                           conversations_repo.with_messages(r.conversation_id)
            turns = Serializers::Conversation.turns_for(conversation, owner: r.owned_by?(user))
            { id: r.id, role: r.role, status: r.status.to_s,
              session_id: r.session_id, conversation_id: r.conversation_id,
              created_at: r.created_at.iso8601(6),
              occurred_at: r.occurred_at&.iso8601(6),
              has_transcript: !r.conversation_id.nil?,
              turns: turns,
              harness: r.harness, model: r.model }
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module Space
  module Server
    module Operations
      # Find-or-create a User from an OmniAuth auth hash, then fail-soft-sync
      # GitHub org memberships. Faithful port of User.from_omniauth +
      # sync_github_orgs! from the Rails oracle. Always returns the user — org
      # sync errors are rescued so a GitHub outage never blocks login.
      class AuthenticateUser
        include Space::Server::Deps["repos.users_repo"]

        def call(auth)
          user = find_or_create(auth)
          sync_orgs(user, auth.credentials&.token)
          user
        end

        private

        def find_or_create(auth)
          uid  = auth.uid.to_s
          info = auth.info
          now  = Time.now
          attrs = {
            username:   info.nickname,
            name:       info.name,
            email:      info.email,
            avatar_url: info.image,
            updated_at: now
          }

          if (existing = users_repo.by_github_uid(uid))
            users_repo.update(existing.id, attrs)
            users_repo.by_pk(existing.id)
          else
            users_repo.create(attrs.merge(github_uid: uid, created_at: now))
          end
        end

        def sync_orgs(user, token)
          return unless token

          orgs = Space::Server::Github.user_orgs(token)
          users_repo.update(user.id, github_orgs: orgs, orgs_synced_at: Time.now)
        rescue Space::Server::Github::Error => e
          Hanami.logger.warn("GitHub org sync failed for #{user.username}: #{e.message}")
        end
      end
    end
  end
end

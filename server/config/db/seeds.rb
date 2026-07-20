# This seeds file should create the database records required to run the app.
#
# The code should be idempotent so that it can be executed at any time.

# Ingest owner user — the user machine-pushed runs (INGEST_TOKEN auth) are
# attributed to. Not a real GitHub account; github_uid/username are synthetic
# but must stay in sync with deploy/ansible/roles/space-architect-server's
# ingest_user_github_uid default, which looks this row up by github_uid to
# resolve INGEST_USER_ID (never hardcoded — BRIEF §7.1).
SEED_INGEST_GITHUB_UID = "ingest-service-account"

users_repo = Space::Server::App["repos.users_repo"]
unless users_repo.by_github_uid(SEED_INGEST_GITHUB_UID)
  now = Time.now
  users_repo.create(
    github_uid: SEED_INGEST_GITHUB_UID,
    username: "ingest",
    name: "Ingest Service Account",
    created_at: now,
    updated_at: now
  )
end

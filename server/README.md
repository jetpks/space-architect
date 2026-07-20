# space-server

A Ruby/Hanami application for exploring and sharing AI chat transcripts. Upload
a Claude conversation export, browse it with rich markdown and code rendering,
annotate individual turns, and share a read-only link with others.

## Setup

```sh
bundle install
npm install
```

Credentials are managed via Hanami's encrypted credentials store:

```sh
bin/credentials edit   # opens $EDITOR; set github_oauth_id/secret and db url
```

## Run

```sh
bin/dev   # starts web server (:3000), Vite (:3036), and the import worker
```

## Test

```sh
bundle exec rake test  # Ruby suite
npm test               # Vitest (TypeScript/component tests)
npm run check          # TypeScript type check
```

## Ingest Token Auth

Machine pushes (e.g. from the CLI dispatch harness) authenticate via a shared secret:

| Env var             | Description                                      |
|---------------------|--------------------------------------------------|
| `INGEST_TOKEN`      | Secret bearer token for `POST /runs` and `POST /runs/:id/ingest` |
| `INGEST_USER_ID`    | Integer user ID that ingested runs are owned by (plain config, not a secret) |
| `INGEST_TOKEN_REF`  | op:// ref `bin/serve` resolves `INGEST_TOKEN` from (default `op://ansible/space-architect-server/ingest-token`) |

When both are set, requests carrying `Authorization: Bearer <INGEST_TOKEN>` are authenticated as the configured user and bypass CSRF (machine pushes carry no session cookie). Browser/cookie requests are unaffected and continue to enforce CSRF normally.

Production boot (`bin/serve`) resolves `INGEST_TOKEN` from the 1Password ref above on every start, so cold-restarting falcon no longer strands ingest auth on a hand-minted, unrecoverable token. A directly-set `INGEST_TOKEN` in the environment bypasses op resolution entirely and is used as-is (`bin/dev`, `bin/live_proof.rb`, and other dev/test flows that mint their own token).

## Deploy on the studio

Production runs as a launchd-supervised `deploy/ansible` role on
`studio.slush.systems` — see `docs/how-to/deploy-on-the-studio.md` for the
apply runbook and `deploy/ansible/README.md` for the role reference.

## Retention & Cleanup (v1: manual)

The inference-jobs pipeline (`lib/space/server/jobs/`) accumulates state in four
places. There is no automated GC in v1 — an operator cleans up by hand when it
matters.

**`space-job-env:*` container images.** `Space::Server::Jobs::EnvImage`
(`lib/space/server/jobs/env_image.rb`) builds one cached image per distinct
`{deps, files_ref, env_keys, base_image}` tuple, tagged
`space-job-env:<sha256[0,12]>`. Nothing ever deletes an old tag. Because
`base_image` now participates in that digest (I11), every `space-job-env:*`
tag built before this change is permanently orphaned — no future job spec can
ever hash to one of those old tags again. List and remove them by hand:

```sh
container image ls | grep space-job-env
container image rm space-job-env:<tag> [space-job-env:<tag> ...]
```

(`container image prune -a` — "remove all unused images, not just dangling
ones" per `container image prune --help` — is a coarser alternative; it also
takes any other unused image on the host, not just `space-job-env:*`.)

**`space-claude-base`.** The sandbox base image jobs actually run in
(`JOB_ENV_BASE_IMAGE`, read in `app/services/executor_worker_service.rb` and
`bin/executor_worker.rb`) is *not* built by `EnvImage` — it's a single
hand-maintained tag built from `images/claude-base/Dockerfile`, per that
file's own header comment:

```sh
container build -f images/claude-base/Dockerfile -t space-claude-base:v1 images/claude-base
```

Rebuild it manually (e.g. to pick up a new `@anthropic-ai/claude-code`
release); bump the `v1` tag and update both read sites above if you want the
old and new base images to coexist during a rollout.

**Per-job sandbox containers.** `lib/space/server/jobs/executor/sandbox_argv.rb`
spawns every job as `container run --rm --cidfile <path> ...`, so a container
that exits on its own removes itself. Verified on this machine: `container ls
-a` shows no per-job containers left behind, only the long-running `buildkit`
builder container (unrelated — it's the image-build helper, not a job
sandbox). The one gap is I09 P5: under Apple `container` 1.0.0 the client
never forwards signals into the sandbox, so if the *executor process itself*
is hard-killed before its `--cidfile`-driven stop path runs, a container can
be orphaned running. Check for strays with `container ls -a` and remove with
`container rm <id>`.

**Redis raw/display streams.** `job:<id>:raw`
(`lib/space/server/jobs/stream_key.rb`) and the mirrored `run:<id>` display
stream self-evict: every `XADD` refreshes the key's TTL to
`StreamKey::TTL_SECONDS` (1800s / 30 minutes), so a stream with no further
writes simply expires. No operator action needed.

**Postgres growth.** `jobs`, `runs`, `conversations`, and `messages` rows are
never deleted by the app — there is no rake task, cron, or GC job. If a table
needs pruning, that's a manual `DELETE` an operator runs directly; no tooling
ships for it in v1.

**Blob storage.** `app/source_file_uploader.rb` stores uploaded conversation
source files via Shrine on the local filesystem (`Shrine::Storage::FileSystem`,
rooted at `storage/cache` and `storage/store` under the app root; test env
uses in-memory storage instead). This is unrelated to job execution — job
output/artifact capture (S3 or otherwise) is out of scope for v1
(BRIEF backlog) — but it's the same "nothing ever deletes it" posture: no
automated cleanup of the `storage/` directory.

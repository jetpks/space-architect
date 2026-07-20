# Deploy on the studio

`space-architect-server` (the inference-job system — web + import worker +
executor worker + consumer worker, one `falcon host falcon.rb` process) runs
on `studio.slush.systems` as a user-level (no root/become) launchd-supervised
service, deployed with the `deploy/ansible` role. See `deploy/ansible/README.md`
for the full role reference; this doc is the apply runbook.

## One-time operator setup

1. **1Password CLI auth.** Place the service-account token at
   `~/.config/secret/op` (mode 0600) — same as the gateway's setup. The
   playbook verifies `op` is reachable; it never creates or reads this file.
2. **1Password items.** Create these under the `ansible` vault,
   `space-architect-server` item, before the first apply:
   - `ingest-token` — the `INGEST_TOKEN` bearer secret (`bin/serve` resolves
     it fresh on every boot; see `server/README.md`).
   - `session-secret` — `SESSION_SECRET` for Hanami's cookie sessions
     (`run-server.sh` resolves it fresh on every boot).
3. **Datastores (brew-owner-provisioned).** PostgreSQL 18.4 and Redis are
   installed and started as Homebrew services by the brew-owner account
   (`eric` has no Homebrew write access — I27). One-time, run as the brew
   owner:
   ```sh
   brew install postgresql@18 redis
   brew services start postgresql@18
   brew services start redis
   ```
4. **`container` CLI (brew-owner-provisioned).** Also installed by the brew
   owner (I27's Homebrew ownership-split finding):
   ```sh
   brew install container
   ```
   The playbook itself runs `container system kernel set --recommended`
   (idempotent, headless) so `container system start` doesn't hit the
   interactive first-run kernel prompt under launchd.

## Apply

From `~/src/space-architect` on the studio:

```sh
ansible-playbook -i deploy/ansible/hosts deploy/ansible/site.yaml
```

Or unattended via ansible-pull:

```sh
deploy/run.sh
```

Both are idempotent and safe to re-run — `bundle install`, `npm ci && npm run
build`, and `hanami db prepare` run on every apply (load-bearing guards, not
one-time setup).

## What comes up

- `com.slushsystems.container` — `container system start`, KeepAlive,
  ordered before the topology so the executor-worker's sandbox runs work on
  first request.
- `com.slushsystems.space-architect-server` — `run-server.sh` resolves
  `SESSION_SECRET` (op) and `INGEST_USER_ID` (looked up by the seeded ingest
  user's `github_uid`, never hardcoded), then execs `bin/serve`, which
  resolves `INGEST_TOKEN` (op) and execs `falcon host falcon.rb`
  (web + import + executor + consumer, one process, KeepAlive).

Verify: `curl localhost:3000/up` → 200.

## Restart / reboot behavior

Falcon killed → launchd (`KeepAlive`) restarts it → `run-server.sh` and
`bin/serve` re-resolve every secret from op, so cold-restarting falcon never
strands ingest auth on a hand-minted token. After a host reboot,
`RunAtLoad` brings the container-system agent and the topology agent back
in order, same as any other `com.slushsystems.*` agent on this host.

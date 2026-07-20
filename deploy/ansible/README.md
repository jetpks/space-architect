# deploy/ansible

Ansible playbook to deploy and keep `space-architect-server` (the inference-job
system: web + import + executor + consumer under one `falcon host falcon.rb`
process) alive on `studio.slush.systems` (macOS, user-level, no root/become).

## Pre-requisites (operator, one-time)

1. **1Password CLI auth** — place the service-account token at
   `~/.config/secret/op` (mode 0600), same as the gateway. The playbook does
   not create this file; it verifies `op` is reachable and reads secrets at
   apply time via `op read 'op://...'`.
2. **1Password items** — `op://ansible/space-architect-server/ingest-token`
   and `op://ansible/space-architect-server/session-secret` must exist
   (same vault/item convention as the gateway's `digitalocean-api-key`).
3. **Datastores** — PostgreSQL 18.4 and Redis are brew-owner-provisioned and
   running as services before the first apply (see "Datastores" below); this
   playbook only verifies connectivity, it never `brew install`s them.
4. **`container` CLI + kernel** — brew-owner-installed (I27: `eric` has no
   Homebrew write access). This playbook verifies `container` is resolvable
   and runs `container system kernel set --recommended` (idempotent,
   headless) so `container system start` doesn't block on the interactive
   first-run kernel prompt.
5. **Ansible collections** — `ansible-galaxy collection install -r deploy/ansible/requirements.yaml`
   (all are already present on `brew install ansible`; `deploy/run.sh`
   installs them itself into its controller venv).

## How to apply

On the studio, from `~/src/space-architect`:

```sh
ansible-playbook -i deploy/ansible/hosts deploy/ansible/site.yaml
```

Or via ansible-pull (runs unattended; re-applies on every pull):

```sh
deploy/run.sh
```

which bootstraps `~/.venv-ansible` and runs the equivalent of:

```sh
ansible-pull -U https://github.com/jetpks/space-architect.git \
  --checkout main -i deploy/ansible/hosts deploy/ansible/site.yaml
```

## What the playbook manages

| Scope item | Result |
|---|---|
| Homebrew PATH | `/opt/homebrew/bin` added to `~/.zprofile` |
| op / container / mise | verified on PATH; none are installed by this playbook |
| mise + Ruby | `ruby@4.0.5` installed and set as global via mise |
| mise + Node | `node@lts` installed and set as global via mise (build-time only) |
| Server checkout | `~/src/space-architect` cloned, pulled on re-apply |
| bundle install | runs before every server restart (load-bearing guard) |
| Production frontend assets | `npm ci && npm run build` — `public/vite/.vite/manifest.json`, served by `vite_hanami` under `RACK_ENV=production` |
| `hanami db prepare` | creates/migrates the schema and seeds the ingest-owner user (`config/db/seeds.rb`) — every apply, idempotent |
| Container-system launchd agent | `com.slushsystems.container` — `container system start`, KeepAlive, ordered before the topology agent |
| Topology launchd agent | `com.slushsystems.space-architect-server` — `run-server.sh` execs `bin/serve` → `falcon host falcon.rb`, KeepAlive |

## Datastores (brew-owner-provisioned)

PostgreSQL 18.4 and Redis are installed and started as Homebrew services by
the brew-owner account (not `eric` — see I27's Homebrew ownership-split
finding). One-time, run as the brew owner:

```sh
brew install postgresql@18 redis
brew services start postgresql@18
brew services start redis
```

This playbook assumes both are already reachable at `localhost` (matching how
the gateway's role assumes its brew deps are pre-provisioned) and connects
via `DATABASE_URL=postgres:///space_server_production` / `REDIS_URL=redis://localhost:6379/0`.

## Secrets

No secret values are committed. `SESSION_SECRET` and `INGEST_TOKEN` are
resolved at every boot from their `op://` refs in `run-server.sh`
(templated by this role) and `bin/serve` respectively — never written to a
file, log, or the launchd plist.

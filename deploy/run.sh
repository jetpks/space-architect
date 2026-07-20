#!/bin/bash
# ansible-pull wrapper for space-architect-server (studio.slush.systems).
# Bootstraps a controller-local ansible venv (~/.venv-ansible) so this runs
# unattended (cron/launchd) without depending on a system ansible install,
# then re-applies the role from a fresh checkout of this repo via
# ansible-pull. A lock dir guards against overlapping runs (e.g. a slow
# apply still in flight when the next scheduled tick fires).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${SPACE_ARCHITECT_REPO_URL:-https://github.com/jetpks/space-architect.git}"
VENV="$HOME/.venv-ansible"
LOCK_DIR="$HOME/.space-architect-deploy.lock"

export PATH="/opt/homebrew/bin:$PATH"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "[run.sh] another deploy is already in flight ($LOCK_DIR exists) — exiting" >&2
  exit 1
fi
trap 'rmdir "$LOCK_DIR"' EXIT

if [ ! -x "$VENV/bin/ansible-pull" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet ansible
fi

export PATH="$VENV/bin:$PATH"

ansible-galaxy collection install -r "$SCRIPT_DIR/ansible/requirements.yaml"

exec ansible-pull \
  --url "$REPO_URL" \
  --checkout main \
  -i deploy/ansible/hosts \
  deploy/ansible/site.yaml

#!/usr/bin/env bash
# Prove pg 1.6.3 compiles FROM SOURCE on linux/amd64 against ruby:4.0.5.
# Exit 0 = source build succeeded; non-zero = build failed.
set -euo pipefail

PG_VERSION="1.6.3"
RUBY_IMAGE="ruby:4.0.5"
PLATFORM="linux/amd64"

echo "=== pg Linux/x86-64 source-compile check ==="
echo "pg version (pinned in architect/Gemfile.lock): ${PG_VERSION}"
echo "Docker image: ${RUBY_IMAGE} (--platform ${PLATFORM})"
echo ""

docker run --rm \
  --platform "${PLATFORM}" \
  -e PG_VERSION="${PG_VERSION}" \
  "${RUBY_IMAGE}" \
  sh -c '
set -e
echo "--- OS / Ruby version ---"
uname -m
ruby --version
echo ""

echo "--- Installing libpq-dev + build tools ---"
apt-get update -qq
apt-get install -y --no-install-recommends libpq-dev build-essential 2>&1
echo ""

echo "--- pg_config location ---"
which pg_config && pg_config --version
echo ""

echo "--- gem install pg --platform=ruby -v ${PG_VERSION} --no-document ---"
gem install pg --platform=ruby -v "${PG_VERSION}" --no-document
echo ""

echo "--- Installed gems matching pg ---"
gem list pg
echo ""

echo "--- Verify pg loads + version ---"
ruby -e "require \"pg\"; puts \"pg loaded: \" + PG::VERSION"
echo ""

echo "--- source-compile evidence: check for pg_ext.so ---"
find / -name "pg_ext.so" -path "*/gems/*" 2>/dev/null | head -5
'

EXIT_CODE=$?
echo ""
echo "=== Exit code: ${EXIT_CODE} ==="
exit "${EXIT_CODE}"

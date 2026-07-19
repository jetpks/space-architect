# Claude-capable sandbox base image (linux/arm64).
#
# Canonical build (from server/):
#   container build -f images/claude-base/Dockerfile -t space-claude-base:v1 images/claude-base
#
# Workers select it via JOB_ENV_BASE_IMAGE=space-claude-base:v1, read at both
# executor construction sites (app/services/executor_worker_service.rb and
# bin/executor_worker.rb); EnvImage layers job-declared apt deps on top.
FROM node:22-slim

# ca-certificates explicitly: the harness needs TLS trust anchors regardless
# of what the base happens to ship.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# `claude` lands on PATH at /usr/local/bin/claude.
RUN npm install -g @anthropic-ai/claude-code

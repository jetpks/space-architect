# How-to guides 🛠️

Goal-oriented recipes: each one solves a specific task. Pick the one that
matches your problem and follow only its steps.

**Tasks:**

- **[Run one full loop iteration](../tutorials/one-loop-iteration.md)** — if
  you have not run the loop at all yet, start with the tutorial instead.
- **[Run parallel lanes](run-parallel-lanes.md)** — fan one iteration out over
  2–4 builders in isolated worktrees, then integrate the passing ones.
- **[Run a research fan-out](run-a-research-fan-out.md)** — dispatch parallel
  read-only researchers before writing a spec.
- **[Install the session-sync rail](install-the-session-sync-rail.md)** —
  upload pi/claude conversation transcripts to a space-server on an interval.
- **[Upgrade from the 8.x monolith](upgrade-from-the-8x-monolith.md)** — move
  to the three-gem 9.x layout without losing config or state.
- **[Deploy on the studio](deploy-on-the-studio.md)** — run
  `space-architect-server` on `studio.slush.systems` (apply runbook).

**Maintainer-facing** (releasing the gem, not using it):

- **[Release a new version](releasing.md)** — the changelog → version bump →
  tag → trusted-publishing procedure, retraced from a real release.

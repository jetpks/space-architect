---
name: architect-action
description: >
  Take over when the discussion is done: write the plan doc and launch the
  coordinator yourself, end to end. Use when the user's intention is to
  START a loop — planning iterations, writing notes/plan-*.md, pinning role
  routing, spawning the coordinator, and handing off. For engineering
  discussion or judgment work, /architect-discuss. For working inline
  outside the loop, /architect.
---

# Architect Action

You are the ARCHITECT taking action: the discussion is over, the human has
disengaged, and the deliverable of this skill is exactly one thing — a
committed plan doc and a launched coordinator. The loop's roles
(spec → builders → judge, driven by the coordinator) do everything after
that.

Read `/architect-discuss` first for the loop's roles, routing, and hard
rules; this skill covers only the start, and it assumes you will not see the
human again until the loop needs them.

## Procedure

1. **Ground (never skip).**
   - `architect status` — iteration/verdict state; anything in flight?
   - `architect looplog --list` — is a loop already running? Fresh transcripts
     mean a live loop: don't double-start; report and ask.
   - Read `architecture/ARCHITECT.md` (TOC + backlog), `architecture/BRIEF.md`
     (the durable §-contract — cite it as BRIEF §N), the in-flight iteration
     file if any, and the latest `notes/spec-digest-*.md` (the previous spec's
     handoff: verification commands actually used, repo seams, house
     conventions, open unknowns — carry its facts forward or they are lost).
   - Read the target repo's `AGENTS.md`/`CLAUDE.md` → `README.md` → docs;
     confirm the exact verification gate command.
   - Learn the verification gate (test/lint/typecheck/build) from docs or CI
     config — the plan's acceptance direction must name it.
2. **Scale the work.** Trivial fixes don't need the loop — say so and do it
   inline (`/architect`). One PR-sized iteration = one ENTRY. Multi-iteration
   plans get ordered ENTRYs (the coordinator works them in order, skipping
   finished ones). If the open question is too uncertain to build, make the
   ENTRY a spike (investigate-only; deliverable is a recommendation — see
   `/architect-discuss`).
3. **Write the plan doc** to `notes/plan-<UTC timestamp>-<name>.md`:

   ```markdown
   # Plan — <name> (<one line>)

   Operator plan <date>. <Repos/lanes in scope.>

   Standing context the spec needs: prior iterations this builds on, routing
   pins, and the post-landing follow-ups (outside-the-loop work the plan
   deliberately excludes — name it so it isn't lost).

   ## ENTRY N — iteration <name> (repo: <repo>, <lane count> lane(s))

   **Objective.** What to build and why — the reason, not just the ask. Cite
   BRIEF §N. If this ENTRY pins model/thinking for a role, say it here (the
   coordinator passes it in that spawn's model field).

   **Grounds to read.** Exact paths: research/bug reports, source files being
   ported, seam files, prior verdicts. The spec reads these before writing
   a word.

   **Acceptance direction (spec refines into frozen AC).** The properties the
   finished iteration must have — at the level the spec can freeze, not
   pre-written gates (freezing is the spec's job).

   **Constraints.** Repos; files that must not change; out-of-scope;
   house-style expectations; what the lane must NOT delete or move (say so
   when a port is replacing something that lives elsewhere).
   ```

   Each ENTRY must be self-contained — the spec agent receives the entry
   verbatim and nothing else. Put the verification gate command in ENTRY
   constraints or grounds.
4. **Pin routing if needed.** Models come from `architect.yaml` (space root
   overrides `~/.config/space-architect/architect.yaml` per role). A
   one-plan pin goes in the plan header/ENTRY (the coordinator passes it in
   that spawn's model field); a standing change edits `architect.yaml`. The
   extension writes the per-space `.pi/agents/` role files from it at
   session start, and every spawn still carries its pin explicitly — nothing
   to hand-sync.
5. **Commit the plan doc** to the space — an uncommitted plan is scratch, and
   decision-bearing documents live in `notes/` (not-committed = didn't
   happen).
6. **Launch it yourself.** You cannot run `/loop` — it is a user command in
   the interactive session, and the human has disengaged. The launch is
   yours: spawn the coordinator directly with the subagent tool —
   - agent `architect-coordinator`, async, cwd = the space root;
   - model = the coordinator's pin from `architect.yaml` (resolve it — read
     the space-local file first, then the global config);
   - `timeoutMs` 43200000 (the 12h coordinator ceiling — never the default);
   - task = the plan text verbatim (paste the full plan doc; the coordinator
     works it iteration by iteration).

   If the human is still around and prefers it, they can run
   `/loop --from notes/plan-<ts>-<name>.md` instead — it validates routing
   and spawns the coordinator detached, so the loop outlives their session.
   Your direct spawn keeps the loop tied to this session staying alive.
7. **Report the handoff, then stay on-call.** Tell the human: the plan path,
   the coordinator run id, and how to watch — `architect looplog` (live),
   `--list` (inventory), `architect status`, `architect cost`. Then: this
   session is the escalation seat — leave it open (a `/compact` whenever
   suits; no timing required) or close it, knowing a coordinator with no
   listener parks questions in `notes/escalation-<ts>.md` and stops via the
   exception path rather than improvising. When you do get an escalation:
   rule on it; the coordinator steers your ruling to the child unchanged.

## Failure modes to check before launching

- **Frozen-region edits** — never edit `architecture/` directly; the plan
  steers, the spec writes sections via the CLI.
- **Stale base** — outside-the-loop commits that landed on a repo's main since
  the last provision are fine (`architect provision` fast-forward-syncs
  `project/<slug>` from the default branch or refuses loudly on divergence);
  a deliberately diverged integration branch must be named in the plan.
- **Stale gem / extension** — if the plan exercises CLI behavior newer than
  the installed gem, note the rebuild in standing context: a config that
  moved ahead of the installed CLI rejects every command. Check
  `architect --version` against the repo when in doubt.

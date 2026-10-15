---
name: architect-plan
description: "Plan work for the architect loop and launch it as an autonomous coordinator run (/loop). Use when the user's intention is to START a loop: planning iterations, writing the plan doc (notes/plan-*.md), pinning role routing, launching the coordinator, and watching it run. For general architecture work without launching a loop (arbitration, judging, landing, iteration surgery, conversation), use /architect instead."
---

# Architect Plan

You are the ARCHITECT planning a coordinator run. The deliverable of this
skill is exactly one thing: a committed plan doc and a launched coordinator.
The loop's roles (spec → builders → judge, driven by the coordinator) do
everything after that — you never absorb a builder wakeup.

Read `/architect` (the main skill) first for roles, routing, and the hard
rules. This skill covers only the start.

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
   inline. One PR-sized iteration = one ENTRY. Multi-iteration plans get
   ordered ENTRYs (the coordinator works them in order, skipping finished
   ones). If the open question is too uncertain to build, make the ENTRY a
   spike (investigate-only; deliverable is a recommendation — see /architect).
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
   ported, seam files, prior verdicts. The spec reads these before writing a
   word.

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
4. **Pin routing if needed.** This plan's models come from `architect.yaml`
   (space root overrides `~/.config/space-architect/architect.yaml` per role).
   A one-plan pin goes in the plan header/ENTRY (the coordinator passes it in
   that spawn's model field); a standing change edits `architect.yaml` —
   routing rides the spawn contract and `/loop` resolves it at launch, so
   there are no generated agent files to hand-sync (the role playbooks are
   static, user-level, installed once by `architect install-agents`).
5. **Commit the plan doc** to the space — an uncommitted plan is scratch, and
   decision-bearing documents live in `notes/` (not-committed = didn't
   happen).
6. **Launch.** From an interactive pi session at the space root:

   ```
   /loop --from notes/plan-<ts>-<name>.md
   ```

   `/loop` refuses an empty plan, resolves the routing config (validates
   every pin against the model registry — a pin it doesn't know throws
   loudly, before any spawn — and injects the per-role pins into the
   coordinator's task), and spawns `architect-coordinator` detached — your
   session may end; the coordinator (12h ceiling) works the plan, narrating
   every settled event to `notes/narrative-*.md`. If pi-subagents' RPC is not
   up in the session, /loop says so — spawn the coordinator directly instead
   (agent `architect-coordinator`, the space as cwd, the plan text verbatim as
   the task, the coordinator's model pin from `architect.yaml`, `timeoutMs`
   43200000).
7. **Report the handoff, then stop.** Tell the human: the plan path, the
   coordinator run id, and how to watch —
   `architect looplog` (live), `--list` (inventory),
   `architect status`, `architect cost`. Escalations route through the
   coordinator to your supervisor seat: rule and the coordinator steers; if
   your session won't stay alive, say so — a coordinator with no listener
   parks the question in `notes/escalation-<ts>.md` and stops via the exception
   path rather than improvising.

## Failure modes to check before launching

- **Frozen-region edits** — never edit `architecture/` directly; the plan
  steers, the spec writes sections via the CLI.
- **Stale base** — outside-the-loop commits that landed on a repo's main since
  the last provision are fine (`architect provision` fast-forward-syncs
  `project/<slug>` from the default branch or refuses loudly on divergence);
  a deliberately diverged integration branch must be named in the plan.
- **Stale gem / extension** — if the plan exercises CLI behavior newer than
  the installed gem, note the rebuild in standing context: a config that
  moved ahead of the installed CLI rejects every command.

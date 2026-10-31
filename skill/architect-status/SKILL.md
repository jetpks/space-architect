---
name: architect-status
description: >
  Answer "what are we working on in here? is it done? what's the current
  state?" for a space-architect workspace — from files and CLI output, never
  from memory or conversation. Read-only: runs the status commands, reads
  the newest notes/narrative-* (and report/exception/escalation notes), and
  summarizes where the space stands. Never judges, never writes, never
  launches anything.
---

# Architect Status

You are the ARCHITECT reporting state. Everything you say is grounded in a
tool result from this session — no recall, no conversation-only claims.

## Procedure

1. **Run the state commands** (read-only, safe any time):

   ```sh
   architect status          # iteration/verdict table
   architect looplog --list # live loop inventory: role runs, ages, tasks
   architect cost           # optional: spend + latency, if the human asks
   ```

2. **Read the newest records** — `notes/narrative-*` first (best-effort
   updates, newest few), and anything newer still: `notes/report-*`
   (loop completion), `notes/exception-*` (why a loop died),
   `notes/escalation-*` (a parked question waiting for the human),
   `notes/plan-*.md` (newest = what the live loop is working). If a loop is
   active, `architect looplog` shows the role runs in flight.

3. **Summarize** in this shape, one line each unless asked for more:

   - **Space:** one line — what this space is for (README/BRIEF, first
     lines only).
   - **Current iteration:** ordinal, name, freeze state, lanes, verdict.
   - **Loop:** live or not; if live, which plan, which role runs are in
     flight and their ages; if not, when the last one settled and how it
     ended (report/exception).
   - **Newest narrative:** what it records — one line of fact.
   - **Waiting on the human:** any escalation or exception note that parks
     a decision.
   - **Next:** what the plan or ARCHITECT.md says comes next.

If nothing is running and nothing is parked, say exactly that — a quiet
space is a finding, not a failure.

## Boundaries

Never judge work, never write anything, never launch or resume a loop.
If the human wants judgment on a finished run, that's `/architect-discuss`;
to start or resume work, `/architect-action`; to do the work directly,
`/architect`.

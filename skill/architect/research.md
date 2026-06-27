# Research fan-out reference

Read this only when a research trigger fires (see SKILL.md step 3). The fan-out
uses `architect research dispatch` to launch parallel read-only `claude -p`
researchers (Sonnet 4.6, no Edit/Write/Bash) and `architect research wait` to
collect their results. The architect keeps all judgment: it verifies
load-bearing claims and writes the iteration's **Grounds** section itself.

**Note:** the `~/.claude/skills/architect-research/` copy of this skill is
synced separately and is NOT updated by this repo.

## Fan out

Decompose the question into 3–5 narrow, NON-OVERLAPPING research questions.
Cover different angles, not the same angle five times — typical split:
official docs/reference, changelog/breaking changes, community failure reports,
alternatives/comparisons, security/operational constraints.

Write each research prompt to its own file, then dispatch and wait:

```bash
# 1. Write one prompt file per research question (use Write tool — do NOT shell-redirect)
#    Filenames: <NN>-<topic>.prompt.md  e.g. 01-official-api.prompt.md

# 2. Dispatch all lanes at once (non-blocking — returns PIDs immediately)
architect research dispatch \
  01-official-api.prompt.md \
  02-changelog.prompt.md

# 3. Wait for all lanes to complete (tails run.jsonl streams; exits non-zero if any lane fails)
architect research wait

# 4. Read each report
cat build/research/01-official-api/report.md
cat build/research/02-changelog/report.md
```

The id for each lane is derived from the prompt filename:
`01-official-api.prompt.md` → id `01-official-api` →
directory `build/research/01-official-api/`.

Verbosity flags for `wait`:
- default (L1): per-lane lifecycle + terminal outcome line
- `--level 2`: + assistant text
- `--level 3`: + tool call names
- `--level 4`: + tool call inputs and results
- `--quiet`: suppress all output; exit status alone signals outcome
- `--thinking`: reveal assistant thinking blocks
- `--jsonl`: emit raw lane-tagged JSONL instead of human text

The researchers are READ-ONLY by toolset (`Read,Grep,Glob,WebSearch,WebFetch`
with no Edit/Write/Bash) so they cannot touch the repo. Their final report
is extracted from the terminal `result` event in the stream-json log and
written to `build/research/<id>/report.md` automatically by `wait`.

## Research-prompt template

```
You are a web research agent. Answer ONE question. Do not write code, do not
make recommendations — judgment belongs to the architect who reads your output.

QUESTION: <one narrow question>

OUTPUT FORMAT — a markdown report:
- Findings as bullets. EVERY finding carries: source URL, source date (if
  shown), the exact figure or a short direct quote, and a confidence tag
  (high = primary source / med = reputable secondary / low = single blog or
  forum post).
- Prefer primary sources (official docs, changelogs, release notes, source
  code) over blog posts. Record exact version numbers and dates.
- When sources disagree, report the disagreement — do not resolve it.
- If you cannot find evidence for something, write NOT FOUND — never infer or
  fill gaps from prior knowledge without flagging it as such.
- End with: the 2-3 findings most likely to change an implementation decision.
```

Keep each researcher scoped to ≤5 subjects and put hard context rules in the
prompt (snippet over page; quote ≤2 sentences; stop the moment you can answer)
— a researcher that fills its context window dies without emitting its report.
Bisect and re-dispatch dead lanes; don't re-run as-is.

## Gather (architect — this is your work, not another agent's)

1. Read every `build/research/<id>/report.md`.
2. Identify the **load-bearing claims** — facts the spec will depend on
   (an API shape, a version constraint, a limit, a deprecation). Adversarially
   verify each: cross-check against a second independent source or the live
   dependency itself. Discard single-source low-confidence claims or mark them
   as open questions.
3. Write the iteration's **Grounds** section
   (`architecture/I<NN>-<name>.md`): problem, decision + why, requirements,
   non-goals, verified facts **with citations**, open questions for the human.
   You write it — researchers gather, the architect judges and decides.
4. Commit Grounds (`I<NN>: grounds`). Raw findings stay in `build/research/`
   (gitignored) — only the distilled, cited Grounds section is repo memory.
5. The iteration's Specification cites Grounds instead of restating it; the
   builder's PHASE 0 is expected to challenge Grounds' claims like anything
   else.

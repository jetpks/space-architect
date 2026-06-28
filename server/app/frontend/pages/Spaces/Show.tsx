import { useMemo, useState } from 'react'
import { Head, Link } from '@inertiajs/react'
import { ChevronDown, ChevronRight } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import Markdown from '@/components/Markdown'
import TurnComponent from '@/components/Turn'
import {
  buildCommandPairs,
  buildFoldedIndex,
  buildToolResultIndex,
  isAbsorbed,
} from '@/lib/message-pairing'
import { isEncryptedThinking } from '@/lib/tools'
import type {
  Annotation,
  ArchitectRun,
  Round as RoundType,
  Space,
  SpaceArtifact,
  SpaceIteration,
  SpaceRun,
  Turn as TurnType,
} from '@/types'
import { KIND_VARIANT, STATUS_VARIANT, VERDICT_VARIANT, formatAbsolute, relativeTime } from './helpers'
import { interleaveTimeline } from './timeline'

type Props = {
  space: Space
  iterations: SpaceIteration[]
  architect_runs: ArchitectRun[]
  unassigned_runs: SpaceRun[]
  other_artifacts: SpaceArtifact[]
}

function ArtifactRow({ spaceId, artifact }: { spaceId: number; artifact: SpaceArtifact }) {
  return (
    <li className="flex items-start gap-2 py-1 text-sm">
      <Badge variant={KIND_VARIANT[artifact.kind] ?? 'outline'} className="mt-0.5 shrink-0">
        {artifact.kind}
      </Badge>
      <Markdown text={artifact.title} />
      <Link
        href={`/spaces/${spaceId}/artifacts/${artifact.id}`}
        className="ml-auto text-xs font-medium hover:underline"
      >
        View
      </Link>
    </li>
  )
}

function RunRow({
  spaceId,
  run,
  gitUtcOffset,
}: {
  spaceId: number
  run: SpaceRun
  gitUtcOffset?: number | null
}) {
  return (
    <li className="flex items-center justify-between py-1 text-sm">
      <div className="flex items-center gap-2">
        <span className="text-muted-foreground">
          {run.lane} ({run.role})
        </span>
        <Badge variant={STATUS_VARIANT[run.status] ?? 'outline'}>{run.status}</Badge>
        {run.created_at && (
          <span className="text-xs text-muted-foreground">
            {relativeTime(run.created_at)}
            {' · '}
            <span className="font-mono">{formatAbsolute(run.created_at, gitUtcOffset)}</span>
          </span>
        )}
      </div>
      <Link
        href={`/spaces/${spaceId}/runs/${run.id}`}
        className="text-xs font-medium hover:underline"
      >
        View transcript
      </Link>
    </li>
  )
}

function DecisionSection({ decision }: { decision: { name: string; body: string } }) {
  return (
    <details className="mb-2 rounded border border-border/50">
      <summary className="cursor-pointer px-3 py-2 text-sm font-medium select-none hover:bg-muted/30">
        {decision.name}
      </summary>
      <div className="overflow-x-auto max-w-full px-3 pb-3 pt-1">
        <Markdown text={decision.body} />
      </div>
    </details>
  )
}

function IterationSection({
  space,
  iteration,
}: {
  space: Space
  iteration: SpaceIteration
}) {
  return (
    <section id={`iteration-${iteration.id}`} className="scroll-mt-20 rounded-lg border border-border p-4">
      <div className="mb-3 flex flex-wrap items-center gap-3">
        <span className="font-mono text-xs text-muted-foreground">
          I{String(iteration.ordinal).padStart(2, '0')}
        </span>
        <h2 className="font-semibold">{iteration.name}</h2>
        {iteration.freeze_sha && (
          <code className="text-xs text-muted-foreground">
            {iteration.freeze_sha.slice(0, 7)}
          </code>
        )}
        {iteration.verdict && (
          <Badge variant={VERDICT_VARIANT[iteration.verdict] ?? 'outline'}>
            {iteration.verdict}
          </Badge>
        )}
        {iteration.occurred_at && (
          <span className="ml-auto text-xs text-muted-foreground">
            {relativeTime(iteration.occurred_at)}
            {' · '}
            <span className="font-mono">{formatAbsolute(iteration.occurred_at, iteration.occurred_at_utc_offset)}</span>
          </span>
        )}
      </div>

      {(iteration.decisions ?? []).length > 0 && (
        <div className="mb-4">
          <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Decisions
          </p>
          {(iteration.decisions ?? []).map((d) => (
            <DecisionSection key={d.name} decision={d} />
          ))}
        </div>
      )}

      {iteration.artifacts.length > 0 && (
        <div className="mb-3">
          <p className="mb-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Artifacts
          </p>
          <ul className="space-y-0.5">
            {iteration.artifacts.map((a) => (
              <ArtifactRow key={a.id} spaceId={space.id} artifact={a} />
            ))}
          </ul>
        </div>
      )}

      {iteration.runs.length > 0 && (
        <div>
          <p className="mb-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Runs
          </p>
          <ul className="space-y-0.5">
            {iteration.runs.map((run) => (
              <RunRow key={run.id} spaceId={space.id} run={run} gitUtcOffset={space.git_utc_offset} />
            ))}
          </ul>
        </div>
      )}
    </section>
  )
}

function ArchitectSessionSection({ space, run }: { space: Space; run: ArchitectRun }) {
  const [expanded, setExpanded] = useState(false)
  const [turns, setTurns] = useState<TurnType[] | null>(null)
  const [loading, setLoading] = useState(false)
  const [fetchError, setFetchError] = useState(false)

  const handleToggle = async () => {
    const opening = !expanded
    setExpanded(opening)
    if (opening && turns === null) {
      if (!run.has_transcript) {
        setTurns([])
      } else {
        setLoading(true)
        try {
          const res = await fetch(`/spaces/${space.id}/runs/${run.id}/transcript`)
          if (!res.ok) throw new Error('fetch failed')
          const data = (await res.json()) as { turns: TurnType[] }
          setTurns(data.turns)
        } catch {
          setFetchError(true)
          setTurns([])
        } finally {
          setLoading(false)
        }
      }
    }
  }

  const allMessages = useMemo(
    () =>
      (turns ?? []).flatMap((t) => [
        ...(t.prompt ? [t.prompt] : []),
        ...t.rounds.flatMap((r) => r.messages),
      ]),
    [turns],
  )
  const toolResults = useMemo(() => buildToolResultIndex(allMessages), [allMessages])
  const commandPairs = useMemo(() => buildCommandPairs(allMessages), [allMessages])
  const emptyAnnotatedIds = useMemo(() => new Set<number>(), [])
  const folded = useMemo(
    () =>
      buildFoldedIndex(
        allMessages,
        toolResults,
        commandPairs.foldedByCommandId,
        emptyAnnotatedIds,
      ),
    [allMessages, toolResults, commandPairs, emptyAnnotatedIds],
  )
  const visibleRounds = useMemo(() => {
    const visible = (turn: TurnType): RoundType[] =>
      turn.rounds
        .map((round) => ({
          anchor_id: round.anchor_id,
          messages: round.messages.filter((m) => {
            if (isEncryptedThinking(m)) return false
            return !isAbsorbed(m, toolResults, emptyAnnotatedIds)
          }),
        }))
        .filter((round) => round.messages.length > 0)
    return new Map((turns ?? []).map((t) => [t.anchor_id, visible(t)]))
  }, [turns, toolResults, emptyAnnotatedIds])
  const emptyAnnotations = useMemo(() => new Map<string, Annotation[]>(), [])
  const owner = useMemo(
    () => ({ username: run.role, name: null, avatar_url: null }),
    [run.role],
  )

  const displayTime = run.occurred_at ?? run.created_at
  const Chevron = expanded ? ChevronDown : ChevronRight

  return (
    <section
      id={`architect-run-${run.id}`}
      className="scroll-mt-20 rounded-lg border border-border p-4"
    >
      <div className="flex flex-wrap items-center gap-3">
        <button
          onClick={() => void handleToggle()}
          aria-label={expanded ? 'Collapse architect session' : 'Expand architect session'}
          className="flex shrink-0 items-center rounded p-0.5 text-muted-foreground transition-colors hover:bg-foreground/5 hover:text-foreground"
        >
          <Chevron className="size-4" />
        </button>
        <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
          architect
        </span>
        <Badge variant={STATUS_VARIANT[run.status] ?? 'outline'}>{run.status}</Badge>
        {displayTime && (
          <span className="ml-auto text-xs text-muted-foreground">
            {relativeTime(displayTime)}
            {' · '}
            <span className="font-mono">{formatAbsolute(displayTime, space.git_utc_offset)}</span>
          </span>
        )}
      </div>

      {expanded && (
        <div className="mt-3">
          {loading && (
            <p className="text-sm text-muted-foreground">Loading transcript…</p>
          )}
          {fetchError && (
            <p className="text-sm text-muted-foreground">Failed to load transcript.</p>
          )}
          {!loading && !fetchError && turns !== null && turns.length === 0 && (
            <p className="text-sm text-muted-foreground">No transcript available.</p>
          )}
          {!loading && !fetchError && turns !== null && turns.length > 0 && (
            <ol className="mt-2 space-y-3">
              {turns.map((turn, i) => (
                <TurnComponent
                  key={turn.anchor_id}
                  anchorId={turn.anchor_id}
                  number={i + 1}
                  prompt={turn.prompt}
                  rounds={visibleRounds.get(turn.anchor_id) ?? []}
                  conversationId={run.conversation_id ?? 0}
                  annotations={emptyAnnotations}
                  toolResults={toolResults}
                  commandStdout={commandPairs.stdoutByMessageId}
                  folded={folded}
                  reveal={null}
                  color="transparent"
                  projectRoot={null}
                  owner={owner}
                />
              ))}
            </ol>
          )}
        </div>
      )}
    </section>
  )
}

export default function Show({
  space,
  iterations,
  architect_runs,
  unassigned_runs,
  other_artifacts,
}: Props) {
  const timeline = interleaveTimeline(iterations, architect_runs)
  const sortedIterations = timeline
    .filter(
      (item): item is { type: 'iteration'; data: SpaceIteration } => item.type === 'iteration',
    )
    .map((item) => item.data)

  return (
    <AppLayout>
      <Head title={space.title} />

      <header className="mb-6 border-b border-border pb-4">
        <h1 className="text-2xl font-bold">{space.title}</h1>
        <p className="mt-1 flex items-center gap-3 text-sm text-muted-foreground">
          {space.slug}
          <Badge variant={STATUS_VARIANT[space.status] ?? 'outline'}>{space.status}</Badge>
        </p>
        {space.repos.length > 0 && (
          <ul className="mt-2 flex flex-wrap gap-3">
            {space.repos.map((repo) => (
              <li key={repo} className="text-xs text-muted-foreground">
                {repo}
              </li>
            ))}
          </ul>
        )}
      </header>

      {sortedIterations.length > 1 && (
        <nav className="mb-6 flex flex-wrap gap-x-4 gap-y-1 text-xs">
          {sortedIterations.map((iter) => (
            <a
              key={iter.id}
              href={`#iteration-${iter.id}`}
              className="text-muted-foreground hover:text-foreground hover:underline"
            >
              I{String(iter.ordinal).padStart(2, '0')}: {iter.name}
            </a>
          ))}
        </nav>
      )}

      {timeline.length === 0 ? (
        <p className="text-sm text-muted-foreground">No iterations yet.</p>
      ) : (
        <div data-testid="timeline" className="space-y-4">
          {timeline.map((item) =>
            item.type === 'iteration' ? (
              <IterationSection
                key={`iter-${item.data.id}`}
                space={space}
                iteration={item.data}
              />
            ) : (
              <ArchitectSessionSection
                key={`arun-${item.data.id}`}
                space={space}
                run={item.data}
              />
            ),
          )}
        </div>
      )}

      {unassigned_runs.length > 0 && (
        <section className="mt-8">
          <h2 className="mb-3 text-lg font-semibold">Unassigned Runs</h2>
          <ul className="space-y-0.5 rounded-lg border border-border p-4">
            {unassigned_runs.map((run) => (
              <RunRow key={run.id} spaceId={space.id} run={run} gitUtcOffset={space.git_utc_offset} />
            ))}
          </ul>
        </section>
      )}

      {other_artifacts.length > 0 && (
        <section className="mt-8">
          <h2 className="mb-3 text-lg font-semibold">Other Artifacts</h2>
          <ul className="space-y-0.5 rounded-lg border border-border p-4">
            {other_artifacts.map((a) => (
              <ArtifactRow key={a.id} spaceId={space.id} artifact={a} />
            ))}
          </ul>
        </section>
      )}
    </AppLayout>
  )
}

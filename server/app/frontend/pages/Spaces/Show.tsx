import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import Markdown from '@/components/Markdown'
import type { ArchitectRun, Space, SpaceArtifact, SpaceIteration, SpaceRun } from '@/types'
import { KIND_VARIANT, STATUS_VARIANT, VERDICT_VARIANT, relativeTime } from './helpers'
import { interleaveTimeline } from './timeline'

type Props = {
  space: Space
  iterations: SpaceIteration[]
  architect_runs: ArchitectRun[]
  unassigned_runs: SpaceRun[]
  other_artifacts: SpaceArtifact[]
}

function ArtifactRow({ artifact }: { artifact: SpaceArtifact }) {
  return (
    <li className="flex items-start gap-2 py-1 text-sm">
      <Badge variant={KIND_VARIANT[artifact.kind] ?? 'outline'} className="mt-0.5 shrink-0">
        {artifact.kind}
      </Badge>
      <Markdown text={artifact.title} />
    </li>
  )
}

function RunRow({ spaceId, run }: { spaceId: number; run: SpaceRun }) {
  return (
    <li className="flex items-center justify-between py-1 text-sm">
      <div className="flex items-center gap-2">
        <span className="text-muted-foreground">
          {run.lane} ({run.role})
        </span>
        <Badge variant={STATUS_VARIANT[run.status] ?? 'outline'}>{run.status}</Badge>
        {run.created_at && (
          <span className="text-xs text-muted-foreground">{relativeTime(run.created_at)}</span>
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
      <div className="px-3 pb-3 pt-1">
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
        {iteration.created_at && (
          <span className="ml-auto text-xs text-muted-foreground">
            {relativeTime(iteration.created_at)}
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
              <ArtifactRow key={a.id} artifact={a} />
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
              <RunRow key={run.id} spaceId={space.id} run={run} />
            ))}
          </ul>
        </div>
      )}
    </section>
  )
}

function ArchitectRunMarker({ run }: { run: ArchitectRun }) {
  return (
    <div className="relative flex items-center py-2">
      <div className="flex-1 border-t border-dashed border-border/60" />
      <div className="mx-4 flex items-center gap-2 text-xs text-muted-foreground">
        <span>architect</span>
        <Badge variant={STATUS_VARIANT[run.status] ?? 'outline'} className="text-[10px]">
          {run.status}
        </Badge>
        <span>{relativeTime(run.created_at)}</span>
      </div>
      <div className="flex-1 border-t border-dashed border-border/60" />
    </div>
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
              <ArchitectRunMarker key={`arun-${item.data.id}`} run={item.data} />
            ),
          )}
        </div>
      )}

      {unassigned_runs.length > 0 && (
        <section className="mt-8">
          <h2 className="mb-3 text-lg font-semibold">Unassigned Runs</h2>
          <ul className="space-y-0.5 rounded-lg border border-border p-4">
            {unassigned_runs.map((run) => (
              <RunRow key={run.id} spaceId={space.id} run={run} />
            ))}
          </ul>
        </section>
      )}

      {other_artifacts.length > 0 && (
        <section className="mt-8">
          <h2 className="mb-3 text-lg font-semibold">Other Artifacts</h2>
          <ul className="space-y-0.5 rounded-lg border border-border p-4">
            {other_artifacts.map((a) => (
              <ArtifactRow key={a.id} artifact={a} />
            ))}
          </ul>
        </section>
      )}
    </AppLayout>
  )
}

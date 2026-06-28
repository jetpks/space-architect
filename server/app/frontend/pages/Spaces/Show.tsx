import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import Markdown from '@/components/Markdown'
import type { Space, SpaceArtifact, SpaceIteration, SpaceRun } from '@/types'
import { KIND_VARIANT, STATUS_VARIANT, VERDICT_VARIANT } from './helpers'

type Props = {
  space: Space
  iterations: SpaceIteration[]
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

function RunRow({ run }: { run: SpaceRun }) {
  return (
    <li className="flex items-center justify-between py-1 text-sm">
      <Link href={`/runs/${run.id}`} className="font-medium hover:underline">
        {run.lane} ({run.role})
      </Link>
      <Badge variant={STATUS_VARIANT[run.status] ?? 'outline'}>{run.status}</Badge>
    </li>
  )
}

export default function Show({ space, iterations, unassigned_runs, other_artifacts }: Props) {
  const sortedIterations = [...iterations].sort((a, b) => a.ordinal - b.ordinal)

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

      <section className="mb-8">
        <h2 className="mb-3 text-lg font-semibold">Iterations</h2>
        {sortedIterations.length === 0 ? (
          <p className="text-sm text-muted-foreground">No iterations yet.</p>
        ) : (
          <ol className="space-y-6">
            {sortedIterations.map((iter) => (
              <li key={iter.id} className="rounded-lg border border-border p-4">
                <div className="mb-3 flex items-center gap-3">
                  <span className="text-xs text-muted-foreground">#{iter.ordinal}</span>
                  <span className="font-medium">{iter.name}</span>
                  {iter.freeze_sha && (
                    <code className="text-xs text-muted-foreground">
                      {iter.freeze_sha.slice(0, 7)}
                    </code>
                  )}
                  {iter.verdict && (
                    <Badge variant={VERDICT_VARIANT[iter.verdict] ?? 'outline'}>
                      {iter.verdict}
                    </Badge>
                  )}
                </div>

                {iter.artifacts.length > 0 && (
                  <div className="mb-3">
                    <p className="mb-1 text-xs font-medium text-muted-foreground">Artifacts</p>
                    <ul className="space-y-0.5">
                      {iter.artifacts.map((a) => (
                        <ArtifactRow key={a.id} artifact={a} />
                      ))}
                    </ul>
                  </div>
                )}

                {iter.runs.length > 0 && (
                  <div>
                    <p className="mb-1 text-xs font-medium text-muted-foreground">Runs</p>
                    <ul className="space-y-0.5">
                      {iter.runs.map((run) => (
                        <RunRow key={run.id} run={run} />
                      ))}
                    </ul>
                  </div>
                )}
              </li>
            ))}
          </ol>
        )}
      </section>

      {unassigned_runs.length > 0 && (
        <section className="mb-8">
          <h2 className="mb-3 text-lg font-semibold">Unassigned Runs</h2>
          <ul className="space-y-0.5 rounded-lg border border-border p-4">
            {unassigned_runs.map((run) => (
              <RunRow key={run.id} run={run} />
            ))}
          </ul>
        </section>
      )}

      {other_artifacts.length > 0 && (
        <section>
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

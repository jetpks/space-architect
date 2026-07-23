import { useState } from 'react'
import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import RunStream from '@/components/RunStream'
import type { SSEState } from '@/lib/sse-reducer'
import type { Run } from '@/types'

type Props = { run: Run }

type BadgeVariant = 'default' | 'secondary' | 'destructive' | 'outline'

// Mirrors Runs/Index.tsx's STATUS_VARIANT — the five run statuses from
// config/db/migrate/20260622000000_create_runs.rb.
const STATUS_VARIANT: Record<string, BadgeVariant> = {
  pending: 'outline',
  live: 'default',
  complete: 'secondary',
  failed: 'destructive',
  canceled: 'outline',
}

export default function Show({ run }: Props) {
  const [streamStatus, setStreamStatus] = useState<SSEState['status']>('pending')

  return (
    <AppLayout>
      <Head title={`Run #${run.id}`} />

      <header className="mb-4 border-b border-border pb-4">
        <h1 className="text-2xl font-bold">Run #{run.id}</h1>
        <p className="mt-1 flex items-center gap-2 text-sm text-muted-foreground">
          <Badge variant={STATUS_VARIANT[run.status] ?? 'outline'}>{run.status}</Badge>
          {run.published && ' · published'}
          {streamStatus === 'live' && ' · streaming'}
        </p>

        <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 text-sm sm:grid-cols-4">
          {run.harness && (
            <div>
              <dt className="text-muted-foreground">Harness</dt>
              <dd>{run.harness}</dd>
            </div>
          )}
          {run.model && (
            <div>
              <dt className="text-muted-foreground">Model</dt>
              <dd>{run.model}</dd>
            </div>
          )}
          {run.role && (
            <div>
              <dt className="text-muted-foreground">Role</dt>
              <dd>{run.role}</dd>
            </div>
          )}
          {run.job && (
            <div>
              <dt className="text-muted-foreground">Job</dt>
              <dd>
                <Link href={`/jobs/${run.job.id}`} className="underline underline-offset-2">
                  #{run.job.id}
                </Link>
                {' · '}
                {run.job.status}
              </dd>
            </div>
          )}
        </dl>

      </header>

      <RunStream runId={run.id} prompt={run.job?.prompt} onStatusChange={setStreamStatus} />
    </AppLayout>
  )
}

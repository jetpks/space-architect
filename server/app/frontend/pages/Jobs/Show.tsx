import { useEffect } from 'react'
import { Head, Link, router } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import AppLayout from '@/layouts/AppLayout'
import type { JobDetail } from '@/types'
import { timeLabel } from '@/pages/Spaces/helpers'
import { STATUS_VARIANT } from './helpers'

type Props = { job: JobDetail }

const ACTIVE_STATUSES = new Set(['queued', 'running'])
const POLL_MS = 2500

export default function Show({ job }: Props) {
  // Self-refresh while the job is still in flight; stop once it lands on a
  // terminal status (succeeded/failed/canceled). No SSE here — /runs/:id owns
  // the live stream once run_id is set.
  useEffect(() => {
    if (!ACTIVE_STATUSES.has(job.status)) return
    const id = setInterval(() => router.reload({ only: ['job'] }), POLL_MS)
    return () => clearInterval(id)
  }, [job.status])

  return (
    <AppLayout>
      <Head title={`Job #${job.id}`} />

      <header className="mb-4 flex items-center justify-between border-b border-border pb-4">
        <h1 className="text-2xl font-bold">Job #{job.id}</h1>
        <Badge variant={STATUS_VARIANT[job.status] ?? 'outline'}>{job.status}</Badge>
      </header>

      <dl className="grid grid-cols-3 gap-4 text-sm">
        <div>
          <dt className="text-muted-foreground">Attempts</dt>
          <dd>{job.attempts}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Created</dt>
          <dd>{timeLabel(job.created_at, null)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Updated</dt>
          <dd>{timeLabel(job.updated_at, null)}</dd>
        </div>
      </dl>

      {job.run_id && (
        <div className="mt-4">
          <Button asChild>
            <Link href={`/runs/${job.run_id}`}>View live run</Link>
          </Button>
        </div>
      )}

      <h2 className="mt-6 text-lg font-semibold">Spec</h2>
      <pre className="mt-2 overflow-x-auto rounded-lg border border-border bg-muted/30 p-3 text-xs">
        {JSON.stringify(job.spec, null, 2)}
      </pre>
    </AppLayout>
  )
}

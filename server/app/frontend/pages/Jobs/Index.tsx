import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import AppLayout from '@/layouts/AppLayout'
import Pagination from '@/components/Pagination'
import type { JobListItem, Pagination as PaginationData } from '@/types'
import { timeLabel } from '@/pages/Spaces/helpers'
import { STATUS_VARIANT } from './helpers'

type Props = { jobs: JobListItem[]; pagination: PaginationData }

export default function Index({ jobs, pagination }: Props) {
  return (
    <AppLayout>
      <Head title="Jobs" />

      <div className="mb-4 flex items-center justify-between">
        <h1 className="text-2xl font-bold">Jobs</h1>
        <Button asChild size="sm">
          <Link href="/jobs/new">New job</Link>
        </Button>
      </div>

      {jobs.length === 0 ? (
        <p className="text-sm text-muted-foreground">No jobs yet.</p>
      ) : (
        <ul className="divide-y divide-border">
          {jobs.map((job) => (
            <li key={job.id} className="flex items-center justify-between gap-4 py-3">
              <div className="min-w-0">
                <Link href={`/jobs/${job.id}`} className="font-medium hover:underline">
                  Job #{job.id} · {[job.harness, job.model].filter(Boolean).join(' · ')}
                </Link>
                {job.provenance && (
                  <p className="mt-1 text-xs text-muted-foreground">
                    {job.provenance.space} · {job.provenance.iteration} · {job.provenance.lane}
                  </p>
                )}
                {job.prompt_snippet && (
                  <p className="mt-1 truncate text-sm text-muted-foreground">{job.prompt_snippet}</p>
                )}
                {job.run_id && (
                  <Link href={`/runs/${job.run_id}`} className="mt-1 block text-xs underline underline-offset-2">
                    Run #{job.run_id}
                  </Link>
                )}
              </div>
              <span className="flex shrink-0 items-center gap-2 text-xs text-muted-foreground">
                <Badge variant={STATUS_VARIANT[job.status] ?? 'outline'}>{job.status}</Badge>
                {timeLabel(job.created_at, null)}
              </span>
            </li>
          ))}
        </ul>
      )}

      <Pagination pagination={pagination} path="/jobs" />
    </AppLayout>
  )
}

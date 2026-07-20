import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import AppLayout from '@/layouts/AppLayout'
import type { JobListItem } from '@/types'
import { timeLabel } from '@/pages/Spaces/helpers'
import { STATUS_VARIANT } from './helpers'

type Props = { jobs: JobListItem[] }

export default function Index({ jobs }: Props) {
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
            <li key={job.id} className="flex items-center justify-between py-3">
              <Link href={`/jobs/${job.id}`} className="font-medium hover:underline">
                Job #{job.id} · {job.model}
              </Link>
              <span className="flex items-center gap-2 text-xs text-muted-foreground">
                <Badge variant={STATUS_VARIANT[job.status] ?? 'outline'}>{job.status}</Badge>
                {timeLabel(job.created_at, null)}
              </span>
            </li>
          ))}
        </ul>
      )}
    </AppLayout>
  )
}

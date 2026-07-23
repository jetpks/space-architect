import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import Pagination from '@/components/Pagination'
import type { RunListItem, Pagination as PaginationData } from '@/types'
import { timeLabel } from '@/pages/Spaces/helpers'

type Props = { runs: RunListItem[]; pagination: PaginationData }

type BadgeVariant = 'default' | 'secondary' | 'destructive' | 'outline'

const STATUS_VARIANT: Record<string, BadgeVariant> = {
  pending: 'outline',
  live: 'default',
  complete: 'secondary',
  failed: 'destructive',
  canceled: 'outline',
}

export default function Index({ runs, pagination }: Props) {
  return (
    <AppLayout>
      <Head title="Runs" />
      <h1 className="mb-4 text-2xl font-bold">Runs</h1>

      {runs.length === 0 ? (
        <p className="text-sm text-muted-foreground">No runs yet.</p>
      ) : (
        <ul className="divide-y divide-border">
          {runs.map((r) => (
            <li key={r.id} className="flex items-center justify-between gap-4 py-3">
              <div className="min-w-0">
                <Link href={`/runs/${r.id}`} className="font-medium hover:underline">
                  Run #{r.id}
                  {(r.harness || r.model || r.lane) && (
                    <span className="ml-2 font-normal text-muted-foreground">
                      {[r.harness, r.model, r.lane].filter(Boolean).join(' · ')}
                    </span>
                  )}
                </Link>
                {r.prompt_snippet && (
                  <p className="mt-1 truncate text-sm text-muted-foreground">{r.prompt_snippet}</p>
                )}
              </div>
              <span className="flex shrink-0 items-center gap-2 text-xs text-muted-foreground">
                <Badge variant={STATUS_VARIANT[r.status] ?? 'outline'}>{r.status}</Badge>
                {timeLabel(r.created_at, null)}
              </span>
            </li>
          ))}
        </ul>
      )}

      <Pagination pagination={pagination} path="/runs" />
    </AppLayout>
  )
}

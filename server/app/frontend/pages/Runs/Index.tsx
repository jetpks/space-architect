import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import type { RunListItem } from '@/types'
import { timeLabel } from '@/pages/Spaces/helpers'

type Props = { runs: RunListItem[] }

type BadgeVariant = 'default' | 'secondary' | 'destructive' | 'outline'

const STATUS_VARIANT: Record<string, BadgeVariant> = {
  pending: 'outline',
  live: 'default',
  complete: 'secondary',
  failed: 'destructive',
}

export default function Index({ runs }: Props) {
  return (
    <AppLayout>
      <Head title="Runs" />
      <h1 className="mb-4 text-2xl font-bold">Runs</h1>

      {runs.length === 0 ? (
        <p className="text-sm text-muted-foreground">No runs yet.</p>
      ) : (
        <ul className="divide-y divide-border">
          {runs.map((r) => (
            <li key={r.id} className="flex items-center justify-between py-3">
              <Link href={`/runs/${r.id}`} className="font-medium hover:underline">
                Run #{r.id}
              </Link>
              <span className="flex items-center gap-2 text-xs text-muted-foreground">
                <Badge variant={STATUS_VARIANT[r.status] ?? 'outline'}>{r.status}</Badge>
                {timeLabel(r.created_at, null)}
              </span>
            </li>
          ))}
        </ul>
      )}
    </AppLayout>
  )
}

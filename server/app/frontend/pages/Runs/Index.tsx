import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import type { RunListItem } from '@/types'

type Props = { runs: RunListItem[] }

type BadgeVariant = 'default' | 'secondary' | 'destructive' | 'outline'

const STATUS_VARIANT: Record<string, BadgeVariant> = {
  pending: 'outline',
  live: 'default',
  complete: 'secondary',
  failed: 'destructive',
}

function relativeTime(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime()
  const minutes = Math.floor(diff / 60_000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
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
                {relativeTime(r.created_at)}
              </span>
            </li>
          ))}
        </ul>
      )}
    </AppLayout>
  )
}

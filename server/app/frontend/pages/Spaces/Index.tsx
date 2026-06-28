import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import type { SpaceListItem } from '@/types'
import { STATUS_VARIANT, timeLabel } from './helpers'

type Props = { spaces: SpaceListItem[] }

export default function Index({ spaces }: Props) {
  return (
    <AppLayout>
      <Head title="Spaces" />
      <h1 className="mb-4 text-2xl font-bold">Spaces</h1>

      {spaces.length === 0 ? (
        <p className="text-sm text-muted-foreground">No spaces yet.</p>
      ) : (
        <ul className="divide-y divide-border">
          {spaces.map((s) => (
            <li key={s.id} className="flex items-center justify-between py-3">
              <Link href={`/spaces/${s.id}`} className="font-medium hover:underline">
                {s.title}
                <span className="ml-2 text-xs text-muted-foreground">{s.slug}</span>
              </Link>
              <span className="flex items-center gap-2 text-xs text-muted-foreground">
                <Badge variant={STATUS_VARIANT[s.status] ?? 'outline'}>{s.status}</Badge>
                {s.iterations_count}i · {s.runs_count}r · {timeLabel(s.imported_at, s.git_utc_offset)}
              </span>
            </li>
          ))}
        </ul>
      )}
    </AppLayout>
  )
}

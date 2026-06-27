import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import type { ConversationListItem } from '@/types'

type Props = { conversations: ConversationListItem[] }

export default function Index({ conversations }: Props) {
  return (
    <AppLayout>
      <Head title="Conversations" />
      <h1 className="mb-4 text-2xl font-bold">Conversations</h1>

      {conversations.length === 0 ? (
        <p className="text-sm text-muted-foreground">No conversations yet.</p>
      ) : (
        <ul className="divide-y divide-border">
          {conversations.map((c) => (
            <li key={c.id} className="flex items-center justify-between py-3">
              <Link href={`/conversations/${c.id}`} className="font-medium hover:underline">
                {c.title}
              </Link>
              <span className="flex items-center gap-2 text-xs text-muted-foreground">
                {c.turns_count} turns · {c.status}
                {c.published && <Badge variant="secondary">published</Badge>}
                {c.owned && !c.published && <Badge variant="outline">private</Badge>}
                {c.shared && <Badge variant="outline">shared with you</Badge>}
              </span>
            </li>
          ))}
        </ul>
      )}
    </AppLayout>
  )
}

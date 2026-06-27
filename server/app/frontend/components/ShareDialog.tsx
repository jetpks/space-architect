import { useState } from 'react'
import { router } from '@inertiajs/react'
import { Building2, Share2, User as UserIcon, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from '@/components/ui/dialog'
import type { Share } from '@/types'

// The owner's grant manager: who can see (and note on) this conversation.
// Type any GitHub login — user vs organization is detected server-side from
// the GitHub API, so there's no kind toggle here.
export default function ShareDialog({
  conversationId,
  shares,
}: {
  conversationId: number
  shares: Share[]
}) {
  const [login, setLogin] = useState('')
  const [access, setAccess] = useState('view')
  const [submitting, setSubmitting] = useState(false)

  const add = (e: React.FormEvent) => {
    e.preventDefault()
    if (!login.trim()) return
    setSubmitting(true)
    router.post(
      `/conversations/${conversationId}/shares`,
      { share: { login: login.trim(), access } },
      {
        preserveScroll: true,
        onSuccess: () => setLogin(''),
        onFinish: () => setSubmitting(false),
      },
    )
  }

  return (
    <Dialog>
      <DialogTrigger asChild>
        <Button size="sm" variant="outline">
          <Share2 /> Share
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Share this conversation</DialogTitle>
          <DialogDescription>
            Grant access to a GitHub user, or to every member of a GitHub organization. View is
            read-only; note also allows adding notes.
          </DialogDescription>
        </DialogHeader>

        {shares.length > 0 && (
          <ul className="grid gap-2">
            {shares.map((share) => (
              <li key={share.id} className="flex items-center gap-2 text-sm">
                <img src={share.avatar_url} alt="" className="size-6 rounded-full bg-muted" />
                {share.grantee_kind === 'org' ? (
                  <Building2 className="size-3.5 text-muted-foreground" />
                ) : (
                  <UserIcon className="size-3.5 text-muted-foreground" />
                )}
                <span className="min-w-0 flex-1 truncate">
                  {share.github_login}
                  {share.grantee_kind === 'org' && (
                    <span className="text-muted-foreground"> (members)</span>
                  )}
                </span>
                <AccessSelect
                  value={share.access}
                  onChange={(value) =>
                    router.patch(
                      `/conversations/${conversationId}/shares/${share.id}`,
                      { share: { access: value } },
                      { preserveScroll: true },
                    )
                  }
                />
                <button
                  onClick={() =>
                    router.delete(`/conversations/${conversationId}/shares/${share.id}`, {
                      preserveScroll: true,
                    })
                  }
                  className="text-muted-foreground transition-colors hover:text-rose-400"
                  aria-label={`Remove share for ${share.github_login}`}
                >
                  <X className="size-4" />
                </button>
              </li>
            ))}
          </ul>
        )}

        <form onSubmit={add} className="flex items-center gap-2">
          <input
            value={login}
            onChange={(e) => setLogin(e.target.value)}
            placeholder="GitHub user or organization"
            className="h-8 min-w-0 flex-1 rounded-md border border-border bg-transparent px-2 text-sm outline-none placeholder:text-muted-foreground focus:border-foreground/30"
          />
          <AccessSelect value={access} onChange={setAccess} />
          <Button type="submit" size="sm" disabled={submitting || !login.trim()}>
            Add
          </Button>
        </form>
      </DialogContent>
    </Dialog>
  )
}

function AccessSelect({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="h-8 rounded-md border border-border bg-transparent px-1 text-sm outline-none focus:border-foreground/30"
      aria-label="Access level"
    >
      <option value="view">view</option>
      <option value="note">note</option>
    </select>
  )
}

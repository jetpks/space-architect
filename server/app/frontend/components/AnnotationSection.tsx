import { useState } from 'react'
import { router, useForm, usePage } from '@inertiajs/react'
import { X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import UserChip from '@/components/UserChip'
import { useCanNote } from '@/lib/use-can-note'
import type { Annotation, NoteTarget, SharedProps } from '@/types'

// The inline notes presentation — a note list + form hanging under its target.
// On wide screens notes live in the margin column instead (NotesColumn); this
// renders only when the margin isn't up, so the same ids and forms never exist
// twice.
type Props = {
  annotations: Annotation[]
  conversationId: number
  target: NoteTarget
  // When provided, the open/closed state is controlled by the parent (a bar
  // menu owns the Annotate trigger). Left undefined, the section shows and owns
  // its own Annotate button (conversation-level usage).
  open?: boolean
  onOpenChange?: (open: boolean) => void
}

export default function AnnotationSection({
  annotations,
  conversationId,
  target,
  open: controlledOpen,
  onOpenChange,
}: Props) {
  const canNote = useCanNote()
  const { current_user } = usePage<SharedProps>().props
  const [internalOpen, setInternalOpen] = useState(false)
  const controlled = controlledOpen !== undefined
  const open = controlled ? controlledOpen : internalOpen
  const setOpen = (value: boolean) => {
    onOpenChange?.(value)
    if (!controlled) setInternalOpen(value)
  }
  const form = useForm({ annotation: { body: '', ...target } })

  // Show nothing when there are no notes and no form to draw: no note access,
  // or the parent owns a (currently closed) trigger.
  const showInternalTrigger = canNote && !controlled
  if (annotations.length === 0 && !open && !showInternalTrigger) return null

  function submit(e: React.FormEvent) {
    e.preventDefault()
    form.post(`/conversations/${conversationId}/annotations`, {
      preserveScroll: true,
      onSuccess: () => {
        form.reset()
        setOpen(false)
      },
    })
  }

  return (
    <div className="mt-3 border-t border-dashed border-border pt-3">
      {annotations.map((annotation) => (
        <div
          key={annotation.id}
          id={`annotation-${annotation.id}`}
          className="mb-2 flex items-start justify-between gap-2 rounded-md border-l-2 border-note/70 bg-muted/40 px-3 py-2 text-sm"
        >
          <div>
            <UserChip
              name={annotation.author}
              avatarUrl={annotation.author_avatar_url}
              className="mr-2 align-middle text-xs font-bold text-primary"
            />
            {annotation.selector && (
              // The quoted passage a range note marks — always shown here, so the
              // note stays readable even when its highlight can't re-anchor.
              <span className="mr-2 italic text-muted-foreground">
                “{clip(annotation.selector.exact)}”
              </span>
            )}
            <span className="whitespace-pre-wrap">{annotation.body}</span>
          </div>
          {annotation.can_delete && (
            <button
              onClick={() =>
                router.delete(`/annotations/${annotation.id}`, {
                  preserveScroll: true,
                })
              }
              className="text-muted-foreground hover:text-rose-400"
              aria-label="Delete note"
            >
              <X className="size-4" />
            </button>
          )}
        </div>
      ))}

      {showInternalTrigger && !open && (
        <Button
          variant="ghost"
          size="sm"
          className="h-7 px-2 text-xs"
          onClick={() => setOpen(true)}
        >
          Add note
        </Button>
      )}

      {canNote && open && (
        <form
          onSubmit={submit}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
              e.preventDefault()
              e.currentTarget.requestSubmit()
            }
          }}
          className="mt-2"
        >
          {current_user && (
            // Who's signing this — notes are public commentary, write accordingly.
            <UserChip
              name={current_user.username}
              avatarUrl={current_user.avatar_url}
              className="mb-1.5 text-xs font-medium text-muted-foreground"
            />
          )}
          <div className="flex items-start gap-2">
            <Textarea
              autoFocus
              value={form.data.annotation.body}
              onChange={(e) =>
                form.setData('annotation', {
                  ...form.data.annotation,
                  body: e.target.value,
                })
              }
              placeholder="Add a note…"
              rows={2}
              className="flex-1"
            />
            <Button type="submit" size="sm" disabled={form.processing}>
              Save
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => {
                form.reset()
                setOpen(false)
              }}
            >
              Cancel
            </Button>
          </div>
        </form>
      )}
    </div>
  )
}

function clip(text: string, max = 80): string {
  return text.length > max ? `${text.slice(0, max).trimEnd()}…` : text
}

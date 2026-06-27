import { useEffect, useRef, useState } from 'react'
import { router, usePage } from '@inertiajs/react'
import { MessageSquarePlus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import UserChip from '@/components/UserChip'
import { buildSelector } from '@/lib/text-anchor'
import { messageIdOf, owningContentEl, rangeToOffsets } from '@/lib/dom-range'
import { setDraftHighlight } from '@/lib/highlight-registry'
import { useCanNote } from '@/lib/use-can-note'
import type { NoteTarget, Selector, SharedProps } from '@/types'

// Google-Docs-style range annotation: select a passage inside one message and
// a floating "Annotate" pill appears over it; click it for a small note form.
// The selection becomes a TextQuoteSelector against the message's rendered
// text (see lib/text-anchor) on a message-targeted annotation. Mounted once
// per Show page — it watches the document, so it adds zero weight to the
// memoized Turn tree.
type Pending = {
  messageId: number
  selector: Selector
  // Viewport coords of the selection's top-center, for the fixed pill.
  top: number
  left: number
}

// The selection clamped to the one message it (mostly) lives in. A selection
// that merely brushes past the message's edge — a triple-click line selection
// routinely parks its end at the START of the next block, which can be outside
// [data-message-content] entirely — shouldn't void the capture; we trim it to
// the content element it starts in. A selection with neither endpoint in
// rendered message content (headers, note lists, source view, our own form)
// stays uncapturable.
function boundedSelection(): { contentEl: HTMLElement; range: Range } | null {
  const selection = document.getSelection()
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null
  const range = selection.getRangeAt(0)
  const contentEl = owningContentEl(range.startContainer) ?? owningContentEl(range.endContainer)
  if (!contentEl) return null

  const bounded = document.createRange()
  bounded.selectNodeContents(contentEl)
  if (bounded.comparePoint(range.startContainer, range.startOffset) === 0) {
    bounded.setStart(range.startContainer, range.startOffset)
  }
  if (bounded.comparePoint(range.endContainer, range.endOffset) === 0) {
    bounded.setEnd(range.endContainer, range.endOffset)
  }
  if (bounded.collapsed) return null
  return { contentEl, range: bounded }
}

// What the current selection means for us: a Pending capture, or null when
// there's nothing capturable under it.
function capture(): Pending | null {
  const captured = boundedSelection()
  if (!captured) return null
  const { contentEl, range } = captured

  const offsets = rangeToOffsets(contentEl, range)
  if (!offsets) return null
  const rect = range.getBoundingClientRect()
  return {
    messageId: messageIdOf(contentEl),
    selector: buildSelector(contentEl.textContent ?? '', offsets.start, offsets.end),
    top: rect.top,
    left: rect.left + rect.width / 2,
  }
}

export default function SelectionAnnotator({
  conversationId,
  onCompose,
}: {
  conversationId: number
  // When the notes margin is up, the pill hands the captured target off to the
  // margin composer instead of opening its own floating form. Before handing
  // off, the live selection Range is registered as a draft highlight — the
  // composer's focus collapses the selection, and the passage must stay marked
  // while its note is written (Show clears the draft when composing ends).
  onCompose?: (target: NoteTarget) => void
}) {
  const canNote = useCanNote()
  const { current_user } = usePage<SharedProps>().props
  const [pending, setPending] = useState<Pending | null>(null)
  const [composing, setComposing] = useState(false)
  const [body, setBody] = useState('')
  const [saving, setSaving] = useState(false)
  const composingRef = useRef(composing)
  composingRef.current = composing
  const containerRef = useRef<HTMLDivElement>(null)

  // The one way out, whatever the path (save, cancel, Escape, outside click):
  // everything resets together, so `composing` can never strand `true` with no
  // form on screen — that deadlock silently swallowed every future selection.
  // Dropping the selection too keeps the pill from instantly re-sprouting over
  // text that's already been dealt with.
  const close = () => {
    setPending(null)
    setComposing(false)
    setBody('')
    document.getSelection()?.removeAllRanges()
  }

  useEffect(() => {
    if (!canNote) return
    // Track selection liveness so the pill follows reality, but only *show* it
    // on settle (mouseup/keyup) — selectionchange fires per character mid-drag.
    let raf = 0
    const sync = (settle: boolean) => {
      if (composingRef.current) return
      cancelAnimationFrame(raf)
      raf = requestAnimationFrame(() => {
        // Re-check at run time, not just at schedule time: the pill click's
        // mouseup schedules this frame, then the click opens the form, whose
        // autoFocus collapses the document selection — without this guard the
        // stale frame would read that collapsed selection and null the pending
        // state right out from under the just-opened form.
        if (composingRef.current) return
        const next = capture()
        // Mid-drag a live selection only repositions an already-shown pill;
        // a settle (or a cleared selection) sets the state outright.
        setPending((prev) => (settle || !next ? next : prev && next))
      })
    }
    const onSettle = () => sync(true)
    const onChange = () => sync(false)
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close()
    }
    document.addEventListener('mouseup', onSettle)
    document.addEventListener('keyup', onSettle)
    document.addEventListener('selectionchange', onChange)
    document.addEventListener('scroll', onChange, {
      passive: true,
      capture: true,
    })
    document.addEventListener('keydown', onKey)
    return () => {
      cancelAnimationFrame(raf)
      document.removeEventListener('mouseup', onSettle)
      document.removeEventListener('keyup', onSettle)
      document.removeEventListener('selectionchange', onChange)
      document.removeEventListener('scroll', onChange, { capture: true })
      document.removeEventListener('keydown', onKey)
    }
    // close only touches stable setters + the DOM, so the first instance is fine.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [canNote])

  // Clicking away from an empty form dismisses it like any popover; once
  // there's typed text, only an explicit Save / Cancel / Escape lets go of it.
  useEffect(() => {
    if (!composing) return
    const onDown = (e: MouseEvent) => {
      if (body.trim()) return
      if (containerRef.current?.contains(e.target as Node)) return
      close()
    }
    document.addEventListener('mousedown', onDown)
    return () => document.removeEventListener('mousedown', onDown)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [composing, body])

  if (!canNote || !pending) return null

  const style: React.CSSProperties = {
    position: 'fixed',
    top: Math.max(8, pending.top - 8),
    left: Math.min(Math.max(pending.left, 16), window.innerWidth - 16),
    transform: 'translate(-50%, -100%)',
    zIndex: 50,
  }

  const submit = (e: React.FormEvent) => {
    e.preventDefault()
    setSaving(true)
    router.post(
      `/conversations/${conversationId}/annotations`,
      {
        annotation: {
          body,
          target_kind: 'message',
          anchor_message_id: pending.messageId,
          selector: pending.selector,
        },
      },
      {
        preserveScroll: true,
        onSuccess: close,
        onFinish: () => setSaving(false),
      },
    )
  }

  return (
    <div ref={containerRef} style={style}>
      {composing ? (
        <form
          onSubmit={submit}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
              e.preventDefault()
              e.currentTarget.requestSubmit()
            }
          }}
          className="w-72 rounded-md border border-border bg-popover p-2 shadow-md"
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
              value={body}
              onChange={(e) => setBody(e.target.value)}
              placeholder={`Note on “${clip(pending.selector.exact)}”…`}
              rows={2}
              className="flex-1"
            />
            <div className="flex flex-col gap-1">
              <Button type="submit" size="sm" disabled={saving || !body.trim()}>
                Save
              </Button>
              <Button type="button" variant="ghost" size="sm" onClick={close}>
                Cancel
              </Button>
            </div>
          </div>
        </form>
      ) : (
        <button
          // preventDefault on mousedown: clicking would otherwise collapse the
          // selection, capture() would return null on the mouseup that follows,
          // and the pill would unmount before this click ever fired.
          onMouseDown={(e) => e.preventDefault()}
          onClick={() => {
            if (onCompose) {
              // The bounded range, not the raw selection — the draft wash must
              // mark exactly what the saved note will highlight.
              setDraftHighlight(boundedSelection()?.range.cloneRange() ?? null)
              onCompose({
                target_kind: 'message',
                anchor_message_id: pending.messageId,
                selector: pending.selector,
              })
              close()
            } else {
              setComposing(true)
            }
          }}
          className="flex items-center gap-1.5 rounded-full border border-border bg-popover px-3 py-1.5 text-xs text-foreground shadow-md transition-colors hover:border-note/70 hover:bg-accent"
        >
          <MessageSquarePlus className="size-3.5" />
          Add note
        </button>
      )}
    </div>
  )
}

function clip(text: string, max = 24): string {
  return text.length > max ? `${text.slice(0, max).trimEnd()}…` : text
}

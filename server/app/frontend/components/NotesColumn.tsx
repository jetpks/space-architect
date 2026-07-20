import { memo, useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { router, usePage } from '@inertiajs/react'
import { X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import UserChip from '@/components/UserChip'
import { layoutNotes, type NoteBox } from '@/lib/note-margin'
import { getAnnotationRange, getDraftRange, setActiveAnnotation } from '@/lib/highlight-registry'
import type { Annotation, NoteTarget, SharedProps } from '@/types'

// The notes margin — the third column on wide screens. The center column is
// for the conversation; commentary about it lives out here, each card sitting
// level with the entity it targets (Google-Docs style), pushed down when
// neighbors would overlap. Cards are absolutely positioned from a measured
// sweep (lib/note-margin) and re-laid-out whenever the transcript's height
// changes — a fold opening, a round revealing — via a ResizeObserver on the
// center column.

const GAP = 8

// What's being composed: the descriptor the new note will POST, plus the same
// candidate chain a saved note would use, so the composer card sits where the
// note will land.
export type ComposeState = { target: NoteTarget; candidates: string[] }

type Props = {
  notes: Annotation[]
  conversationId: number
  // Per-note DOM-id candidate chains (most precise first), precomputed in Show.
  candidates: Map<number, string[]>
  composing: ComposeState | null
  onComposeEnd: () => void
  // Jump the transcript to a note's target (the same reveal/scroll path the
  // TOC and deep links use).
  onSelect: (note: Annotation) => void
  // The center column — observed for size changes that move targets.
  contentRef: React.RefObject<HTMLDivElement | null>
}

function mapsEqual(a: Map<string, number>, b: Map<string, number>): boolean {
  if (a.size !== b.size) return false
  for (const [key, value] of b) if (a.get(key) !== value) return false
  return true
}

function NotesColumn({
  notes,
  conversationId,
  candidates,
  composing,
  onComposeEnd,
  onSelect,
  contentRef,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null)
  const cardRefs = useRef(new Map<string, HTMLDivElement>())
  const [tops, setTops] = useState<Map<string, number>>(new Map())
  const [minHeight, setMinHeight] = useState(0)
  // The transcript element currently ringed because its note is hovered.
  const hintedRef = useRef<HTMLElement | null>(null)
  // Keys whose settled position has already been painted. A card's FIRST
  // position must apply instantly — it mounts at top 0 before the measuring
  // pass, and animating 0 → settled reads as the card flying down the rail.
  // Only repositions of an already-painted card (folds reflowing the
  // transcript) get the transition. Updated after paint, so the render that
  // first positions a key still sees it as unpainted.
  const paintedRef = useRef<Set<string>>(new Set())
  useEffect(() => {
    paintedRef.current = new Set(tops.keys())
  })
  const cardClass = (key: string) =>
    `absolute inset-x-0 ${paintedRef.current.has(key) ? 'transition-[top] duration-200' : ''}`

  const setCardRef = (key: string) => (el: HTMLDivElement | null) => {
    if (el) cardRefs.current.set(key, el)
    else cardRefs.current.delete(key)
  }

  const relayout = useCallback(() => {
    const container = containerRef.current
    if (!container) return
    const containerTop = container.getBoundingClientRect().top
    // First mounted candidate wins — a folded-away target falls back to its
    // round, then its turn, so every note always has somewhere to sit.
    const anchorTopFor = (ids: string[]): number => {
      for (const id of ids) {
        const el = document.getElementById(id)
        if (el) return el.getBoundingClientRect().top - containerTop
      }
      return 0
    }
    // A range note sits level with its painted passage, not the top of the
    // (possibly very long) message holding it. A zero-height rect means the
    // range is detached or unresolved — fall through to the element chain.
    const passageTopFor = (range: Range | null): number | null => {
      if (!range || range.collapsed) return null
      const rect = range.getBoundingClientRect()
      if (rect.height === 0) return null
      return rect.top - containerTop
    }
    const boxes: NoteBox[] = notes.map((note) => ({
      key: `n${note.id}`,
      anchorTop:
        (note.selector ? passageTopFor(getAnnotationRange(note.id)) : null) ??
        anchorTopFor(candidates.get(note.id) ?? []),
      height: cardRefs.current.get(`n${note.id}`)?.offsetHeight ?? 0,
    }))
    if (composing) {
      // Same deal for the draft: anchored to the selected passage, so the
      // composer never spawns at the message top — possibly off-screen — when
      // the selection sits deep inside a long message.
      boxes.push({
        key: 'composer',
        anchorTop:
          (composing.target.selector ? passageTopFor(getDraftRange()) : null) ??
          anchorTopFor(composing.candidates),
        height: cardRefs.current.get('composer')?.offsetHeight ?? 0,
      })
    }
    const next = layoutNotes(boxes, GAP)
    let bottom = 0
    for (const box of boxes) bottom = Math.max(bottom, (next.get(box.key) ?? 0) + box.height)
    setMinHeight(bottom)
    setTops((prev) => (mapsEqual(prev, next) ? prev : next))
  }, [notes, candidates, composing])

  // Measure after every commit of this column (cards just rendered at possibly
  // stale tops; heights are top-independent, so one corrective pass converges —
  // the equality guard above stops the loop). Runs before paint, so the first
  // frame already shows settled positions.
  useLayoutEffect(() => {
    relayout()
  })

  // Targets move when the transcript reflows — folds opening, gaps revealing,
  // images settling. The center column's size changes with all of them.
  useEffect(() => {
    const el = contentRef.current
    if (!el) return
    const observer = new ResizeObserver(() => relayout())
    observer.observe(el)
    window.addEventListener('resize', relayout)
    return () => {
      observer.disconnect()
      window.removeEventListener('resize', relayout)
    }
  }, [relayout, contentRef])

  const hint = (ids: string[] | undefined, on: boolean) => {
    hintedRef.current?.classList.remove('note-target-hint')
    hintedRef.current = null
    if (!on || !ids) return
    for (const id of ids) {
      const el = document.getElementById(id)
      if (el) {
        el.classList.add('note-target-hint')
        hintedRef.current = el
        return
      }
    }
  }
  // Hovering a card lights its target: a range note gets the full
  // highlighter-pen wash on its exact passage; anything else gets the element
  // ring (a passage is sharper than ringing the whole message around it).
  const hover = (note: Annotation, on: boolean) => {
    if (note.selector) setActiveAnnotation(on ? note.id : null)
    else hint(candidates.get(note.id), on)
  }
  useEffect(
    () => () => {
      hint(undefined, false)
      setActiveAnnotation(null)
    },
    [],
  )

  return (
    <div ref={containerRef} className="relative" style={{ minHeight }}>
      {notes.map((note) => (
        <div
          key={note.id}
          ref={setCardRef(`n${note.id}`)}
          style={{ top: tops.get(`n${note.id}`) ?? 0 }}
          className={cardClass(`n${note.id}`)}
        >
          <div
            id={`annotation-${note.id}`}
            onClick={() => onSelect(note)}
            onMouseEnter={() => hover(note, true)}
            onMouseLeave={() => hover(note, false)}
            className="cursor-pointer rounded-md border border-border border-l-2 border-l-note/60 bg-card p-3 shadow-sm transition-colors hover:border-note/70"
          >
            <div className="mb-1 flex items-center gap-2">
              <UserChip
                name={note.author}
                avatarUrl={note.author_avatar_url}
                className="text-xs font-bold text-primary"
              />
              <span className="text-[10px] uppercase tracking-wide text-muted-foreground/70">
                {note.target_kind}
              </span>
              {note.can_delete && (
                <button
                  onClick={(e) => {
                    e.stopPropagation()
                    router.delete(`/annotations/${note.id}`, { preserveScroll: true })
                  }}
                  className="ml-auto text-muted-foreground hover:text-destructive"
                  aria-label="Delete note"
                >
                  <X className="size-3.5" />
                </button>
              )}
            </div>
            {note.selector && (
              // The quoted passage a range note marks — kept on the card, so the
              // note reads on its own even when the highlight can't re-anchor.
              // The note-yellow wash mirrors the passage's highlight: same ink,
              // both places.
              <p className="mb-1 rounded-sm bg-note/15 px-1.5 py-0.5 text-xs italic text-muted-foreground">
                “{clip(note.selector.exact)}”
              </p>
            )}
            <p className="whitespace-pre-wrap text-sm">{note.body}</p>
          </div>
        </div>
      ))}

      {composing && (
        <div
          ref={setCardRef('composer')}
          style={{ top: tops.get('composer') ?? 0 }}
          className={cardClass('composer')}
        >
          <Composer
            // Retargeting (annotate something else mid-compose) starts fresh.
            key={composeKey(composing.target)}
            conversationId={conversationId}
            target={composing.target}
            onDone={onComposeEnd}
          />
        </div>
      )}
    </div>
  )
}

function composeKey(target: NoteTarget): string {
  return `${target.target_kind}:${target.anchor_message_id ?? ''}:${target.selector?.position ?? ''}`
}

function Composer({
  conversationId,
  target,
  onDone,
}: {
  conversationId: number
  target: NoteTarget
  onDone: () => void
}) {
  const { current_user } = usePage<SharedProps>().props
  const [body, setBody] = useState('')
  const [saving, setSaving] = useState(false)
  // Focus without scrolling: the card mounts at the rail's top before the
  // measuring pass places it, and React's autoFocus runs right then — the
  // browser would yank the viewport to the top of the page, then the card
  // would animate away to its real spot. preventScroll keeps the viewport
  // where the user just selected.
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  useLayoutEffect(() => {
    textareaRef.current?.focus({ preventScroll: true })
  }, [])

  const submit = (e: React.FormEvent) => {
    e.preventDefault()
    setSaving(true)
    router.post(
      `/conversations/${conversationId}/annotations`,
      { annotation: { body, ...target } },
      {
        preserveScroll: true,
        onSuccess: onDone,
        onFinish: () => setSaving(false),
      },
    )
  }

  return (
    <form
      onSubmit={submit}
      onKeyDown={(e) => {
        if (e.key === 'Escape') onDone()
        if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
          e.preventDefault()
          e.currentTarget.requestSubmit()
        }
      }}
      className="rounded-md border border-note/70 bg-card p-3 shadow-md"
    >
      <div className="mb-1 flex items-center justify-between gap-2">
        {current_user && (
          // Who's signing this — notes are public commentary, write accordingly.
          <UserChip
            name={current_user.username}
            avatarUrl={current_user.avatar_url}
            className="text-xs font-medium text-muted-foreground"
          />
        )}
        <p className="text-[10px] uppercase tracking-wide text-muted-foreground/70">
          note on {target.selector ? 'selection' : target.target_kind}
        </p>
      </div>
      {target.selector && (
        <p className="mb-1 rounded-sm bg-note/15 px-1.5 py-0.5 text-xs italic text-muted-foreground">
          “{clip(target.selector.exact)}”
        </p>
      )}
      <Textarea
        ref={textareaRef}
        value={body}
        onChange={(e) => setBody(e.target.value)}
        placeholder="Add a note…"
        rows={3}
        className="mb-2"
      />
      <div className="flex gap-2">
        <Button type="submit" size="sm" disabled={saving || !body.trim()}>
          Save
        </Button>
        <Button type="button" variant="ghost" size="sm" onClick={onDone}>
          Cancel
        </Button>
      </div>
    </form>
  )
}

function clip(text: string, max = 100): string {
  return text.length > max ? `${text.slice(0, max).trimEnd()}…` : text
}

export default memo(NotesColumn)

import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { Badge } from '@/components/ui/badge'
import Block from '@/components/Block'
import SourceView from '@/components/SourceView'
import AnnotationSection from '@/components/AnnotationSection'
import BarMenu from '@/components/BarMenu'
import { SECTION_HEADER } from '@/lib/tools'
import { resolveSelector } from '@/lib/text-anchor'
import { offsetAtPoint, offsetsToRange } from '@/lib/dom-range'
import {
  clearMessageHighlights,
  setActiveAnnotation,
  setMessageHighlights,
  type HighlightEntry,
} from '@/lib/highlight-registry'
import { ExpandClampsContext } from '@/lib/expand-clamps'
import type { Marker } from '@/lib/tools'
import type { Annotation, Message as MessageType, NoteTarget, ToolResultIndex } from '@/types'

export default function Message({
  message,
  conversationId,
  annotations = [],
  toolResults,
  commandStdout,
  folded,
  bare = false,
  headerHighlight = false,
  label,
  marker,
  hideMenu = false,
  showSource: showSourceProp,
  annotateOpen: annotateOpenProp,
  onAnnotateChange,
  onCompose,
}: {
  message: MessageType
  conversationId: number
  // This message's own (message-targeted) notes, sliced from the conversation's
  // flat annotation list by the owner.
  annotations?: Annotation[]
  toolResults?: ToolResultIndex
  commandStdout?: string
  // A marked beat (decision/memory/commit): its tool header shows the glyph + color.
  marker?: Marker
  // Turns folded into this one (paired tool results), shown in the source view.
  folded?: MessageType[]
  // Drop the card chrome (border/bg/padding) — used when the message renders
  // inside another surface that already provides it (e.g. an expanded action
  // row's pressed-in panel), so we don't double up the border.
  bare?: boolean
  // Render the header as a tinted section band (matching Turn's prompt/thought
  // headers) — used when this message *is* a turn section (the terminal), not a
  // nested beat. Off for leads and tool details, which are just plain headers.
  headerHighlight?: boolean
  // What this message *is* in its context — "round" for a round lead, "tool" for a
  // tool detail. Defaults to the raw role. We stopped labeling every nested beat
  // "assistant" (it was noise on every lead and tool); the structural name is clearer.
  label?: string
  // Suppress this message's own ⋯ menu — used when an owning bar (a round or tool
  // row) already carries one for it, so the two don't stack side by side. The bar
  // then drives the source view and annotation form through the controlled props.
  hideMenu?: boolean
  // Controlled source-view / annotation-form open-state. When omitted each falls
  // back to its own local state — the standalone terminal message keeps its menu
  // and owns these itself; a body message reads them from its bar (which toggles
  // source) and reports annotation-form closes back up via onAnnotateChange.
  showSource?: boolean
  annotateOpen?: boolean
  onAnnotateChange?: (open: boolean) => void
  // When the notes margin is up, "Add note" composes out there instead of
  // opening the inline form, and the inline note list stays unrendered (the
  // margin shows the notes — and owns the `annotation-…` ids).
  onCompose?: (target: NoteTarget) => void
}) {
  const [showSourceSelf, setShowSourceSelf] = useState(false)
  const showSource = showSourceProp ?? showSourceSelf

  const [annotateOpenSelf, setAnnotateOpenSelf] = useState(false)
  const annotateOpen = annotateOpenProp ?? annotateOpenSelf
  const setAnnotateOpen = onAnnotateChange ?? setAnnotateOpenSelf

  // Range annotations paint as highlights over this message's rendered text.
  // Re-anchored on every render (no dep array): any re-render — a clamp toggle,
  // a source flip — invalidates the live Ranges, and a per-message text scan is
  // cheap. The resolved spans stick around for click hit-testing.
  const ref = useRef<HTMLDivElement>(null)
  const spansRef = useRef<{ annotation: Annotation; start: number; end: number }[]>([])
  const rangeAnnotations = annotations.filter((a) => a.selector)
  useLayoutEffect(() => {
    const el = ref.current
    spansRef.current = []
    if (!el || showSource || rangeAnnotations.length === 0) {
      clearMessageHighlights(message.id)
      return
    }
    const text = el.textContent ?? ''
    const entries: HighlightEntry[] = []
    for (const annotation of rangeAnnotations) {
      const span = resolveSelector(text, annotation.selector!)
      if (!span) continue // quote no longer occurs — the note still lists below
      const range = offsetsToRange(el, span.start, span.end)
      if (!range) continue
      entries.push({ annotationId: annotation.id, range })
      spansRef.current.push({ annotation, ...span })
    }
    setMessageHighlights(message.id, entries)
    return () => clearMessageHighlights(message.id)
  })

  // Clicking a painted highlight flashes its note in the list below, tying the
  // marked passage to the commentary about it.
  const onContentClick = (e: React.MouseEvent) => {
    if (spansRef.current.length === 0 || !ref.current) return
    const offset = offsetAtPoint(ref.current, e.clientX, e.clientY)
    if (offset == null) return
    const hit = spansRef.current.find((s) => offset >= s.start && offset < s.end)
    if (!hit) return
    const note = document.getElementById(`annotation-${hit.annotation.id}`)
    if (!note) return
    note.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
    note.classList.add('anchor-flash')
    note.addEventListener('animationend', () => note.classList.remove('anchor-flash'), {
      once: true,
    })
  }

  // Hovering a painted highlight is the card hover mirrored: the passage gets
  // the full-pen active wash and its card the same border cue the card's own
  // hover shows — the tether works from either end. Hit-testing per mousemove
  // is rAF-throttled (caretPositionFromPoint forces a layout hit test); all
  // state lives in refs and classList, so tracking never re-renders the tree.
  const hoveredNoteRef = useRef<number | null>(null)
  const hoverRaf = useRef(0)
  const setHoveredNote = (id: number | null) => {
    if (hoveredNoteRef.current === id) return
    document
      .getElementById(`annotation-${hoveredNoteRef.current}`)
      ?.classList.remove('note-card-hint')
    hoveredNoteRef.current = id
    setActiveAnnotation(id)
    if (id != null) document.getElementById(`annotation-${id}`)?.classList.add('note-card-hint')
    // Over a live passage the text is clickable (click flashes the card).
    if (ref.current) ref.current.style.cursor = id != null ? 'pointer' : ''
  }
  const onContentMouseMove = (e: React.MouseEvent) => {
    if (spansRef.current.length === 0 || !ref.current) return
    const { clientX, clientY } = e
    cancelAnimationFrame(hoverRaf.current)
    hoverRaf.current = requestAnimationFrame(() => {
      if (!ref.current) return
      const offset = offsetAtPoint(ref.current, clientX, clientY)
      const hit =
        offset == null
          ? undefined
          : spansRef.current.find((s) => offset >= s.start && offset < s.end)
      setHoveredNote(hit ? hit.annotation.id : null)
    })
  }
  const onContentMouseLeave = () => {
    cancelAnimationFrame(hoverRaf.current)
    setHoveredNote(null)
  }
  // Let go of an in-flight hover if the message unmounts under it (a fold).
  useEffect(
    () => () => {
      cancelAnimationFrame(hoverRaf.current)
      setHoveredNote(null)
    },
    // setHoveredNote only touches refs and the registry; first instance is fine.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  )

  // With the menu gone and no title/badge to show (a bare lead or tool detail), the
  // header row would be an empty strip — drop it and let the content sit flush.
  const title = label ?? message.role
  const showHeader = !hideMenu || !!title || message.published

  return (
    <div
      id={`message-${message.id}`}
      // scroll-mt clears the sticky turn bar when a note card or deep link
      // jumps here (block: 'start') — same offset every other anchor row uses.
      className={bare ? 'scroll-mt-20' : 'scroll-mt-20 rounded-lg border border-border bg-card p-4'}
    >
      {showHeader && (
        <div
          className={
            headerHighlight
              ? SECTION_HEADER
              : 'mb-2 flex items-center gap-2 text-xs uppercase tracking-wide text-muted-foreground'
          }
        >
          <span className="font-bold text-foreground">{title}</span>
          {message.published && <Badge variant="secondary">turn published</Badge>}
          {!hideMenu && (
            // Every action for this message — source, copy source, permalink, annotate —
            // collapses into one ⋯ menu pinned to the header's right edge.
            <div className="ml-auto">
              <BarMenu
                label="Message actions"
                anchor={`message-${message.id}`}
                source={{ shown: showSource, onToggle: () => setShowSourceSelf((v) => !v) }}
                copySource={() => JSON.stringify(message.blocks, null, 2)}
                annotate={() =>
                  onCompose
                    ? onCompose({ target_kind: 'message', anchor_message_id: message.id })
                    : setAnnotateOpen(!annotateOpen)
                }
              />
            </div>
          )}
        </div>
      )}

      {showSource ? (
        <SourceView blocks={message.blocks} folded={folded} />
      ) : (
        // data-message-content scopes text selection and highlight re-anchoring
        // to the rendered blocks — the annotation list below (which quotes the
        // selected text back) and the header must never match a selector.
        <div
          ref={ref}
          onClick={onContentClick}
          onMouseMove={onContentMouseMove}
          onMouseLeave={onContentMouseLeave}
          data-message-content={message.id}
          className="space-y-2"
        >
          {/* A range note's passage can sit past a clamp ("show more" prose,
              collapsed output/code) — with notes present, clamps default open
              so the highlight is visible on load. */}
          <ExpandClampsContext.Provider value={rangeAnnotations.length > 0}>
            {message.blocks.map((block, i) => (
              <Block
                key={i}
                block={block}
                toolResults={toolResults}
                commandStdout={commandStdout}
                marker={marker}
              />
            ))}
          </ExpandClampsContext.Provider>
        </div>
      )}

      {!onCompose && (
        <AnnotationSection
          annotations={annotations}
          conversationId={conversationId}
          target={{ target_kind: 'message', anchor_message_id: message.id }}
          open={annotateOpen}
          onOpenChange={setAnnotateOpen}
        />
      )}
    </div>
  )
}

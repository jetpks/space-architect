import { useEffect, useRef } from 'react'
import { gist, markerLabel, MARKER_STYLE, turnMarkers } from '@/lib/tools'
import { turnMessages } from '@/lib/anchors'
import type { Turn as TurnType } from '@/types'

// How many turns to keep visible on either side of the active band, so you can
// always see where you're heading rather than scrolling into the unknown.
const CONTEXT = 3

// The per-turn tint is deliberately very dark (12% L) — a wash behind a whole
// column. As a small highlight on the TOC's dark rail that's too faint, so the
// active entry uses a brighter variant: bump the lightness (the 3rd value of the
// `hsl(H 38% 12%)` turnColor emits) and lift saturation a touch so the hue reads.
function brighten(color: string): string {
  return color
    .replace(/(\d+(?:\.\d+)?)%\)$/, (_, l) => `${Math.min(100, Number(l) + 10)}%)`)
    .replace(/38%/, '42%')
}

// A jump-nav for the transcript: one entry per turn (its prompt gist, or
// "preamble"), with decision points listed as emerald sub-entries beneath their
// turn. Decisions are jump targets, not turn boundaries — see memory
// chat-share-decisions-not-boundaries. onJump opens the target turn (state lives
// in Show) and scrolls to the turn, or to the decision divider within it. When
// `scrollable`, the rail is its own scroll container and auto-follows the active
// band (the turns currently on screen) keeping ±CONTEXT turns in view.
export default function TurnToc({
  turns,
  colors,
  active,
  projectRoot,
  onJump,
  scrollable = false,
}: {
  turns: TurnType[]
  // Per-turn tint (matches the main column). An entry stays on the default dark
  // background and only lights up to its color while its turn is on screen.
  colors: Map<number, string>
  active: Set<number>
  projectRoot: string | null
  // Jump to a turn, or to a marked beat within it (target = `${marker}-${id}`).
  // revealId names the marker's message so its turn can open the round holding it.
  onJump: (anchorId: number, target?: string, revealId?: number) => void
  scrollable?: boolean
}) {
  const containerRef = useRef<HTMLElement>(null)
  const headerRef = useRef<HTMLParagraphElement>(null)
  const entryRefs = useRef(new Map<number, HTMLLIElement>())

  // Follow the active band: scroll the rail (minimally, only when the margin is
  // breached) so the active turns plus ±CONTEXT neighbors stay visible. The move
  // is instant, not smooth: during a fast scroll `active` changes every frame, and
  // a fresh smooth scrollTo each frame restarts its easing from a standstill — so
  // it stayed stuck in the slow initial acceleration and never kept up. Instant
  // tracking matches the now-per-frame highlight; explicit TOC-click jumps keep
  // their one-shot smooth scroll in Show.
  useEffect(() => {
    if (!scrollable) return
    const container = containerRef.current
    if (!container) return
    const activeIdx = turns.flatMap((t, i) => (active.has(t.anchor_id) ? [i] : []))
    if (activeIdx.length === 0) return

    const firstEl = entryRefs.current.get(turns[Math.max(0, Math.min(...activeIdx) - CONTEXT)].anchor_id)
    const lastEl = entryRefs.current.get(
      turns[Math.min(turns.length - 1, Math.max(...activeIdx) + CONTEXT)].anchor_id,
    )
    if (!firstEl || !lastEl) return

    // The "Turns" header is sticky at the top of this scroll container, so reveal
    // the upper edge below it — scrolling to a bare offsetTop tucks the top turn
    // under the header. (The bottom edge isn't covered, so that branch is plain.)
    const headerH = headerRef.current?.offsetHeight ?? 0
    const viewTop = container.scrollTop
    const viewBottom = viewTop + container.clientHeight
    const needTop = firstEl.offsetTop - headerH
    const needBottom = lastEl.offsetTop + lastEl.offsetHeight
    if (needTop < viewTop) container.scrollTop = needTop
    else if (needBottom > viewBottom) container.scrollTop = needBottom - container.clientHeight
  }, [active, turns, scrollable])

  return (
    <nav
      ref={containerRef}
      aria-label="Turns"
      className={scrollable ? 'relative max-h-[calc(100vh-3rem)] overflow-y-auto pr-2' : undefined}
    >
      <p
        ref={headerRef}
        className="sticky top-0 z-10 mb-2 bg-background pb-1 text-xs font-bold uppercase tracking-wide text-muted-foreground"
      >
        Turns
      </p>
      <ol className="space-y-1.5">
        {turns.map((turn, i) => {
          const prompt = turn.prompt
          const markers = turnMarkers(turnMessages(turn), projectRoot)
          const isActive = active.has(turn.anchor_id)
          return (
            <li
              key={turn.anchor_id}
              ref={(el) => {
                const m = entryRefs.current
                if (el) m.set(turn.anchor_id, el)
                else m.delete(turn.anchor_id)
              }}
              // The active tint underlays the whole entry — prompt and its markers
              // — as one rounded block; the fill is its own separator, so an active
              // entry just hides the rule (border kept transparent, not removed) and
              // padding stays identical, so row height never changes between
              // active/inactive — otherwise the rail juddered as rows flipped.
              style={isActive ? { backgroundColor: brighten(colors.get(turn.anchor_id) ?? 'transparent') } : undefined}
              className={`border-b px-1.5 py-1 ${isActive ? 'rounded border-transparent' : 'border-border/40'}`}
            >
              <button
                onClick={() => onJump(turn.anchor_id)}
                className={`block w-full truncate text-left text-sm transition-colors ${
                  isActive ? 'text-foreground' : 'text-muted-foreground hover:text-foreground'
                }`}
              >
                {/* The 1-based turn number, matching the "Turn N" bar in the
                    content column so the rail ties to what's on screen. */}
                <span className="mr-1.5 tabular-nums text-xs text-muted-foreground/60">{i + 1}</span>
                {prompt ? gist(prompt, 60) : <span className="italic">preamble</span>}
              </button>
              {markers.length > 0 && (
                <ul className="ml-2 mt-0.5 space-y-0.5 border-l border-border/40 pl-2">
                  {markers.map(({ message, marker }) => {
                    const style = MARKER_STYLE[marker]
                    return (
                      <li key={message.id}>
                        <button
                          onClick={() => onJump(turn.anchor_id, `${marker}-${message.id}`, message.id)}
                          className={`block w-full truncate text-left text-xs ${style.subtle} ${style.textHover}`}
                        >
                          {style.glyph} {markerLabel(message, marker, projectRoot)}
                        </button>
                      </li>
                    )
                  })}
                </ul>
              )}
            </li>
          )
        })}
      </ol>
    </nav>
  )
}

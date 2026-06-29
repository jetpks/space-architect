import { memo, useEffect, useState } from 'react'
import { ChevronDown, ChevronRight } from 'lucide-react'
import Message from '@/components/Message'
import AnnotationSection from '@/components/AnnotationSection'
import BarMenu from '@/components/BarMenu'
import UserChip from '@/components/UserChip'
import {
  gist,
  isActionMessage,
  isCompactSummary,
  MARKER_STYLE,
  messageMarker,
  toolLabel,
} from '@/lib/tools'
import { annotationsFor } from '@/lib/annotation-index'
import type {
  Annotation,
  Message as MessageType,
  NoteTarget,
  Round as RoundType,
  ToolUseBlock,
  ToolResultIndex,
} from '@/types'

// A clickable label for an intermediate row: its gist, or — when it has no
// narrative text (a bare tool call) — a tool descriptor so the row is still
// meaningful and expandable.
function rowLabel(message: MessageType, max = 64): string {
  const g = gist(message, max)
  if (g) return g
  const tool = message.blocks.find((b) => b.type === 'tool_use') as ToolUseBlock | undefined
  if (tool) return toolLabel(tool, max)
  return message.blocks.map((b) => b.type).join(', ') || 'message'
}

// A one-line label for a whole round: its narrative gist (the "what's about to
// happen"), or — when the round opens straight into a tool with no narrative —
// the first action's descriptor, so a collapsed round still reads.
function roundLabel(round: RoundType): string {
  for (const m of round.messages) {
    const g = gist(m, 80)
    if (g) return g
  }
  const tool = round.messages.flatMap((m) => m.blocks).find((b) => b.type === 'tool_use') as
    | ToolUseBlock
    | undefined
  return tool ? toolLabel(tool, 80) : 'step'
}

// A fold row in the rounds tree, shared by round keys and action rows: a
// borderless, full-width toggle — chevron + label — that runs flush to the turn
// frame on the right and only lights a subtle hover wash. Depth is NOT a box
// around each row anymore (which walled content in on both sides as you nested);
// it reads from the left rail its *open* content sits in. So a row is just a
// heading, the rail beneath it is the indent — like a word processor's outline.
// `tint` overrides the resting text color (markers); omit for the default muted look.
function rowClass(tint?: string | null): string {
  return `flex w-full items-center gap-2 rounded px-1 py-1 text-left transition-colors hover:bg-foreground/5 ${
    tint ?? 'text-muted-foreground hover:text-foreground'
  }`
}

// Every fold (round or action) is bracketed: a top border across the whole row +
// a left gutter meeting it at the corner. Open, the bracket grows to wrap the body
// too (the wrapper contains it), anchoring body to row; closed, it's just the short
// corner on the row — which is the point of keeping it ALWAYS on: a minimized tool
// would otherwise vanish between a round's prose and an open tool below it. It's
// open on the right + bottom (no box, just an indent step), and since the border is
// always present, toggling never shifts the row by a pixel. Width only — the color
// is appended per use (neutral normally, the marker's tint on a marked tool row).
const FOLD_FRAME = 'rounded-tl-md border-l border-t'
const FOLD_BORDER = 'border-border/60'
// The body inside that bracket: indented one step past the gutter (its depth) and
// given a little bottom room before the open edge.
const FOLD_BODY = 'pb-1 pl-3'

// A tiny count of the notes a collapsed round/tool row is sitting on — the
// progressive-disclosure hint that there's commentary behind the fold, in the
// row's existing right cluster rather than a new surface.
function NoteChip({ count }: { count: number }) {
  return (
    <span
      className="shrink-0 self-center text-xs text-primary/70"
      title={`${count} note${count === 1 ? '' : 's'}`}
    >
      ¶{count}
    </span>
  )
}

// The "show N more rounds (M tools)" divider that stands in for a collapsed run of
// elided rounds — a clickable rule revealing them in place. Same shape in both
// zooms (the expanded gap and the collapsed gist); `dense` tightens it for the
// gist, where rows sit closer together.
function GapDivider({
  rounds,
  onClick,
  dense = false,
}: {
  rounds: RoundType[]
  onClick: () => void
  dense?: boolean
}) {
  const tools = rounds.reduce((sum, r) => sum + r.messages.filter(isActionMessage).length, 0)
  const rule = <span className="h-px flex-1 bg-border/60" />
  return (
    <button
      onClick={onClick}
      className={`flex w-full items-center text-xs text-muted-foreground hover:text-foreground ${
        dense ? 'gap-2 py-0.5' : 'gap-3 py-1'
      }`}
    >
      {rule}
      <span className="shrink-0">
        show {rounds.length} more round{rounds.length === 1 ? '' : 's'} ({tools} tool
        {tools === 1 ? '' : 's'})
      </span>
      {rule}
    </button>
  )
}

// Turns short enough to read whole stay whole; past this many rounds we elide
// the middle, keeping this many rounds of context at each end.
const ROUND_THRESHOLD = 8
const ROUND_CONTEXT = 3

// A laid-out rounds list: kept rounds interleaved with collapsed gaps.
type RoundItem = { kind: 'round'; round: RoundType } | { kind: 'gap'; rounds: RoundType[] }

function roundHasMarker(round: RoundType, projectRoot: string | null): boolean {
  return round.messages.some((m) => messageMarker(m, projectRoot) !== null)
}

// Decide which rounds stay visible and which fold into "show N more" gaps. Short
// turns show every round. Longer ones keep the first and last few rounds, plus
// every marker-bearing round and its immediate neighbors — a marker always
// appears with a round on either side — and collapse each remaining contiguous
// run into one gap. Markers anywhere therefore split the elision around them.
// A round holding the reveal target (a deep link or TOC jump into the fold) is
// force-kept the same way, so the jump never lands behind a "show more" divider.
function planRounds(
  rounds: RoundType[],
  projectRoot: string | null,
  reveal: number | null,
  noted: Set<number>,
): RoundItem[] {
  if (rounds.length <= ROUND_THRESHOLD) {
    return rounds.map((round) => ({ kind: 'round', round }))
  }
  const n = rounds.length
  const keep = new Set<number>()
  for (let i = 0; i < n; i++) {
    if (i < ROUND_CONTEXT || i >= n - ROUND_CONTEXT) keep.add(i)
    // A round carrying notes (its own or a member's) never hides in a gap —
    // notes must be visible on load.
    if (noted.has(rounds[i].anchor_id)) keep.add(i)
    // Match the anchor id too, not just member ids: a redacted-thinking anchor
    // is filtered out of the visible member list, but `#round-<id>` still
    // names it.
    if (
      reveal != null &&
      (rounds[i].anchor_id === reveal || rounds[i].messages.some((m) => m.id === reveal))
    ) {
      keep.add(i)
    }
    if (roundHasMarker(rounds[i], projectRoot)) {
      keep.add(i)
      if (i > 0) keep.add(i - 1)
      if (i < n - 1) keep.add(i + 1)
    }
  }
  const items: RoundItem[] = []
  for (let i = 0; i < n; ) {
    if (keep.has(i)) {
      items.push({ kind: 'round', round: rounds[i] })
      i++
    } else {
      const gap: RoundType[] = []
      while (i < n && !keep.has(i)) gap.push(rounds[i++])
      items.push({ kind: 'gap', rounds: gap })
    }
  }
  return items
}

// A turn is the unit the page organizes around. It renders one way: prompt and
// terminal in full (compact) markdown, with the intermediate work as a list of
// folded round rows you open individually (or all at once via the bar menu). A
// turn at rest is still short — folded rounds are one line each, and long turns
// elide their middle rounds into "show N more" gaps — but there's no whole-turn
// fold anymore; you shrink a turn by folding its rounds. Turn-level notes live on
// the anchor (prompt) message; body messages keep their own.
// Memoized: Show re-renders on every activeTurns tick while scrolling, but a
// turn's props are all stable across those (Show memoizes the derived data), so a
// turn only re-renders when its own disclosure state or content actually changes
// — keeping fast scroll from redrawing the transcript.
function Turn({
  anchorId,
  number,
  prompt,
  rounds,
  conversationId,
  annotations,
  toolResults,
  commandStdout,
  folded,
  reveal,
  color,
  projectRoot,
  owner,
  onCompose,
}: {
  anchorId: number
  // 1-based position in the conversation, shown in the turn's bar.
  number: number
  prompt: MessageType | null
  // The turn's non-prompt members, partitioned into rounds by the server and
  // filtered down to the viewer-visible messages in Show.
  rounds: RoundType[]
  conversationId: number
  // The conversation's whole annotation index (one stable Map, built in Show) —
  // sliced here by (kind, anchor) for the turn, its prompt, rounds, and tools.
  annotations: Map<string, Annotation[]>
  toolResults: ToolResultIndex
  commandStdout: Record<number, string>
  folded: Record<number, MessageType[]>
  // A message in this turn that a TOC jump or deep link asked us to reveal
  // (else null) — we open the round (and tool row) holding it so the buried
  // beat actually shows. Scoped to the owning turn in Show so a jump doesn't
  // churn every turn's memo.
  reveal: number | null
  // Per-turn background tint (cycled by index in Show) so you can sense position
  // while scrolling; the same color lights up the TOC entry when it's on screen.
  color: string
  // The conversation's project root, used to detect memory writes (a /memory/
  // file outside the repo) — highlighted orange like decisions are emerald.
  projectRoot: string | null
  // Who wrote the prompts — stamped on each turn's user message. (One identity
  // per conversation today; per-message authorship would replace this.)
  owner: { username: string; name: string | null; avatar_url: string | null }
  // When the notes margin is up, every "Add note" here composes out there
  // (handed the target descriptor) and the inline note sections stay
  // unrendered — the margin shows the notes. Absent on narrow screens, where
  // the inline sections still carry them.
  onCompose?: (target: NoteTarget) => void
}) {
  const [showSource, setShowSource] = useState(false)
  const [turnAnnotateOpen, setTurnAnnotateOpen] = useState(false)
  const [promptAnnotateOpen, setPromptAnnotateOpen] = useState(false)
  const [summaryOpen, setSummaryOpen] = useState(false)

  // A /compact turn carries the continuation summary Claude Code injected before
  // the command — machinery, not work. Pull it out of the rounds so it doesn't
  // read as the turn's content (it'd otherwise become the "terminal"); it renders
  // as a collapsed disclosure of its own. See lib/tools isCompactSummary.
  const allMessages = rounds.flatMap((r) => r.messages)
  const summary = allMessages.find((m) => isCompactSummary(m)) ?? null
  const content = summary ? allMessages.filter((m) => m.id !== summary.id) : allMessages

  // The terminal message is the turn's last content message (the agent's
  // summary); the rounds before it are intermediate work. Both peels happen at
  // render time — the server's rounds are a complete partition — so a round
  // emptied by them just drops out.
  const terminal = content.length > 0 ? content[content.length - 1] : null
  const intermediateRounds = rounds
    .map((r) => ({
      ...r,
      messages: r.messages.filter((m) => m.id !== summary?.id && m.id !== terminal?.id),
    }))
    .filter((r) => r.messages.length > 0)
  const intermediate = intermediateRounds.flatMap((r) => r.messages)

  // A note must be visible on load. Message-level notes (a tool note, or a
  // range note over a tool's rendered detail) live on content that collapsed
  // rounds and closed action rows don't even mount — so a noted message's
  // round starts open and its row expanded. Round-level notes stay collapsed:
  // their target is the round row itself, which shows its ¶ chip either way.
  const hasOwnNotes = (m: MessageType) =>
    annotationsFor(annotations, 'message', m.id).length > 0 ||
    annotationsFor(annotations, 'tool', m.id).length > 0
  const notedRounds = new Set(
    intermediateRounds
      .filter(
        (r) =>
          annotationsFor(annotations, 'round', r.anchor_id).length > 0 ||
          r.messages.some(hasOwnNotes),
      )
      .map((r) => r.anchor_id),
  )

  // Disclosure state inside a turn: which collapsed gaps have been revealed,
  // which rounds are open (the plumbing-taming layer), and — within an open
  // round — which individual action rows are open.
  const [shownGaps, setShownGaps] = useState<Set<number>>(new Set())
  const [expandedRounds, setExpandedRounds] = useState<Set<number>>(
    () =>
      new Set(
        intermediateRounds.filter((r) => r.messages.some(hasOwnNotes)).map((r) => r.anchor_id),
      ),
  )
  // The last message a jump asked this turn to reveal — see the reveal effect.
  const [lastReveal, setLastReveal] = useState<number | null>(null)
  // Per-body-message source state, lifted here so a round *bar* menu can drive
  // the message rendered in its body — the message itself no longer carries a
  // menu of its own. Keyed by message id.
  const [sourceIds, setSourceIds] = useState<Set<number>>(new Set())
  // Open annotation forms for round-targeted notes, keyed by the round's anchor id.
  const [roundAnnotate, setRoundAnnotate] = useState<Set<number>>(new Set())

  const toggle = (set: Set<number>, id: number) => {
    const next = new Set(set)
    next.has(id) ? next.delete(id) : next.add(id)
    return next
  }
  const setFlag = (set: Set<number>, id: number, on: boolean) => {
    const next = new Set(set)
    on ? next.add(id) : next.delete(id)
    return next
  }
  const toggleGap = (id: number) => setShownGaps((prev) => toggle(prev, id))
  const toggleSource = (id: number) => setSourceIds((prev) => toggle(prev, id))
  const ensureOpen = (set: Set<number>, setter: typeof setExpandedRounds, id: number) => {
    if (!set.has(id)) setter((prev) => new Set(prev).add(id))
  }

  const actionsOf = (messages: MessageType[]) => messages.filter(isActionMessage)

  const openRound = (round: RoundType) => {
    setExpandedRounds((prev) => toggle(prev, round.anchor_id))
  }

  const renderMessage = (
    message: MessageType,
    bare = false,
    headerHighlight = false,
    label?: string,
  ) => (
    <Message
      message={message}
      conversationId={conversationId}
      annotations={annotationsFor(annotations, 'message', message.id)}
      toolResults={toolResults}
      commandStdout={commandStdout[message.id]}
      folded={folded[message.id]}
      bare={bare}
      headerHighlight={headerHighlight}
      label={label}
      onCompose={onCompose}
    />
  )

  // A message rendered inside a round/tool body: menu-less (its bar owns the menu),
  // with its source view driven by the lifted, id-keyed state so the bar's menu
  // items toggle it. `label=""` drops the structural role label too, so a bare
  // lead/detail sits flush with no empty header strip. Its message-targeted notes
  // (e.g. range annotations) still render with it.
  const bodyMessage = (message: MessageType) => (
    <Message
      message={message}
      conversationId={conversationId}
      annotations={annotationsFor(annotations, 'message', message.id)}
      toolResults={toolResults}
      commandStdout={commandStdout[message.id]}
      folded={folded[message.id]}
      bare
      hideMenu
      label=""
      marker={messageMarker(message, projectRoot) ?? undefined}
      showSource={sourceIds.has(message.id)}
      onCompose={onCompose}
    />
  )

  // An action (tool call) rendered inline inside its open round — no fold, no
  // chevron, no per-tool bar. The anchor id preserves deep-link targets and the
  // margin's note alignment; marked tools get their marker-prefixed id so TOC
  // jumps still land. Tool body renders via bodyMessage (bare, menu-less) and
  // existing tool-targeted notes display below it. New notes are created by
  // text selection (SelectionAnnotator) rather than a per-tool button.
  const renderActionRow = (message: MessageType) => {
    const marker = messageMarker(message, projectRoot)
    const anchor = marker ? `${marker}-${message.id}` : `tool-${message.id}`
    const toolUseId = (
      message.blocks.find((b) => b.type === 'tool_use') as ToolUseBlock | undefined
    )?.id
    const toolNotes = annotationsFor(annotations, 'tool', message.id)

    return (
      <div key={message.id} id={anchor} className="scroll-mt-20">
        {bodyMessage(message)}
        {!onCompose && (
          <AnnotationSection
            annotations={toolNotes}
            conversationId={conversationId}
            target={{
              target_kind: 'tool',
              anchor_message_id: message.id,
              tool_use_id: toolUseId,
            }}
            open={false}
          />
        )}
      </div>
    )
  }

  // A round of thought. A chevron at its top-left is the toggle; the round's
  // content sits in a column to the chevron's right. Collapsed, that column reads
  // like the original gist — the lead's one-line narrative (a marked beat keeps its
  // tinted glyph), tool count on the end of the first line, any extra beats stacked
  // below. Open, the SAME column unfurls in place: the chevron just rotates to point
  // down and the lead's full bright prose grows from the very spot its gist sat —
  // filling to the right and below — with the tool rows it spawned underneath. The
  // chevron's slot is held in both states so nothing shifts sideways on the toggle.
  const renderRound = (round: RoundType) => {
    const id = round.anchor_id
    const isOpen = expandedRounds.has(id)
    const leads = round.messages.filter((m) => !isActionMessage(m))
    const actions = actionsOf(round.messages)
    const Chevron = isOpen ? ChevronDown : ChevronRight
    const roundNotes = annotationsFor(annotations, 'round', id)

    // The round bar's source / copy act on the round's narrative lead (its first
    // non-action message). A round that opens straight into a tool has no lead,
    // so those items fall back to disabled. Annotate targets the round itself.
    const lead = leads[0] ?? null

    const menu = (
      <BarMenu
        label="Round actions"
        anchor={`round-${id}`}
        fold={{
          expanded: isOpen,
          onExpand: () => openRound(round),
          onCollapse: () => openRound(round),
          noun: 'round',
        }}
        all={{ onExpand: expandAllRounds, onCollapse: collapseAllRounds, noun: 'rounds' }}
        source={
          lead
            ? {
                shown: sourceIds.has(lead.id),
                // The lead only renders while the round is open — opening source opens it.
                onToggle: () => {
                  ensureOpen(expandedRounds, setExpandedRounds, id)
                  toggleSource(lead.id)
                },
              }
            : undefined
        }
        copySource={lead ? () => JSON.stringify(lead.blocks, null, 2) : undefined}
        annotate={() => {
          ensureOpen(expandedRounds, setExpandedRounds, id)
          if (onCompose) onCompose({ target_kind: 'round', anchor_message_id: id })
          else setRoundAnnotate((prev) => toggle(prev, id))
        }}
      />
    )

    // The beats worth a collapsed line: any narrative message (has a gist) plus
    // every marker (a bare tool call gets its tool descriptor). Plain tool-only
    // beats drop out — they have no story — so the gist reads as prose, not plumbing.
    const beats = round.messages.filter((m) => messageMarker(m, projectRoot) || gist(m, 96))
    const lines = beats.length ? beats : [round.messages[0]]

    return (
      <div key={id} id={`round-${id}`} className="group/round scroll-mt-20">
        <div className="flex items-start gap-1.5">
          {/* The toggle — its slot is the same width open or closed, so the content
              column to its right never moves; only the glyph rotates ▸ → ▾. */}
          <button
            onClick={() => openRound(round)}
            aria-label={isOpen ? 'Collapse round' : 'Expand round'}
            className="shrink-0 rounded p-0.5 text-muted-foreground transition-colors hover:bg-foreground/5 hover:text-foreground"
          >
            <Chevron className="size-3.5" />
          </button>

          <div className="min-w-0 flex-1">
            {isOpen ? (
              // The same column the gist sat in, now unfurled: the lead's full prose
              // (menu-less — the round menu drives its source), the round's own notes,
              // then the tool rows it spawned, filling to the right and below.
              <div className="space-y-2">
                {leads.map((m) => (
                  <div key={m.id}>{bodyMessage(m)}</div>
                ))}
                {!onCompose && (
                  <AnnotationSection
                    annotations={roundNotes}
                    conversationId={conversationId}
                    target={{ target_kind: 'round', anchor_message_id: id }}
                    open={roundAnnotate.has(id)}
                    onOpenChange={(open) => setRoundAnnotate((prev) => setFlag(prev, id, open))}
                  />
                )}
                {actions.length > 0 && (
                  <div className="space-y-1">{actions.map(renderActionRow)}</div>
                )}
              </div>
            ) : (
              <div className="space-y-0.5">
                {lines.map((m) => {
                  const mk = messageMarker(m, projectRoot)
                  const st = mk ? MARKER_STYLE[mk] : null
                  const label = mk ? rowLabel(m, 96) : gist(m, 96) || roundLabel(round)
                  return (
                    <button
                      key={m.id}
                      // Markers carry the precise anchor the TOC jumps to; the round
                      // container holds the `round-${id}` anchor for the rest.
                      id={mk ? `${mk}-${m.id}` : undefined}
                      onClick={() => openRound(round)}
                      aria-label="Expand round"
                      className={`flex w-full items-baseline gap-1.5 text-left text-xs leading-snug transition-colors ${
                        st
                          ? `${st.text} ${st.textHover}`
                          : 'text-muted-foreground hover:text-foreground'
                      }`}
                    >
                      {st && <span className="shrink-0">{st.glyph}</span>}
                      <span className="min-w-0 flex-1 truncate">{label}</span>
                    </button>
                  )
                })}
              </div>
            )}
          </div>

          {/* The right cluster — the round's tool count and its menu — is present only
              while the round is collapsed. When open, the content column extends to
              the full container width so the inline tool rows aren't permanently
              narrowed by a reserved right gutter. Hover-reveal slot is held while
              collapsed so nothing jumps on expand. */}
          {!isOpen && (
            <div className="flex shrink-0 items-center gap-1.5">
              {roundNotes.length > 0 && <NoteChip count={roundNotes.length} />}
              {actions.length > 0 && (
                <span className="text-xs text-muted-foreground/70">
                  {actions.length} tool{actions.length === 1 ? '' : 's'}
                </span>
              )}
              <div className="opacity-0 transition-opacity group-hover/round:opacity-100">
                {menu}
              </div>
            </div>
          )}
        </div>
      </div>
    )
  }

  // A collapsed run of elided rounds — a clickable divider that reveals them in
  // place. Keyed by the first round's anchor so reveal-state is stable.
  const renderGap = (gapRounds: RoundType[]) => {
    const key = gapRounds[0].anchor_id
    if (shownGaps.has(key)) {
      return (
        <div key={`gap-${key}`} className="space-y-1">
          {gapRounds.map(renderRound)}
        </div>
      )
    }
    return <GapDivider key={`gap-${key}`} rounds={gapRounds} onClick={() => toggleGap(key)} />
  }

  const roundItems = planRounds(intermediateRounds, projectRoot, reveal ?? lastReveal, notedRounds)

  // The id of every elided gap, so revealing "all" un-hides them too.
  const gapKeys = () =>
    roundItems.flatMap((it) => (it.kind === 'gap' ? [it.rounds[0].anchor_id] : []))

  // Whole-turn fold controls, shared by the round/turn bar menus. Opening all
  // rounds reveals their tools inline; collapsing clears round state only.
  const expandAllRounds = () => {
    setShownGaps(new Set(gapKeys()))
    setExpandedRounds(new Set(intermediateRounds.map((r) => r.anchor_id)))
  }
  const collapseAllRounds = () => {
    setShownGaps(new Set())
    setExpandedRounds(new Set())
  }

  // A TOC jump or deep link into a collapsed round asks us to reveal its target:
  // open the round that holds it — tool calls display inline once the round is
  // open, so no second step is needed. Marker and reveal rounds are force-kept
  // by planRounds, so the round is never elided behind a "show more" gap.
  useEffect(() => {
    if (reveal == null) return
    // Keep the reveal sticky: Show clears revealId once the scroll lands, and
    // without a remembered value planRounds would fold the just-visited round
    // straight back into its gap.
    setLastReveal(reveal)
    const round = intermediateRounds.find((r) => r.messages.some((m) => m.id === reveal))
    if (!round) return
    setExpandedRounds((prev) =>
      prev.has(round.anchor_id) ? prev : new Set(prev).add(round.anchor_id),
    )
    // intermediateRounds is derived from stable props; intentionally keyed only on
    // reveal so a manual collapse isn't undone on the next unrelated render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reveal])

  // The turn bar's menu. Source / copy delegate to the prompt (disabled on a
  // prompt-less preamble); annotate targets the turn itself, so it's always
  // available. The all-rounds controls open or fold every round at once.
  const turnMenu = (
    <BarMenu
      label="Turn actions"
      anchor={`turn-${anchorId}`}
      all={{ onExpand: expandAllRounds, onCollapse: collapseAllRounds, noun: 'rounds' }}
      source={prompt ? { shown: showSource, onToggle: () => setShowSource((v) => !v) } : undefined}
      copySource={prompt ? () => JSON.stringify(prompt.blocks, null, 2) : undefined}
      annotate={() =>
        onCompose
          ? onCompose({ target_kind: 'turn', anchor_message_id: anchorId })
          : setTurnAnnotateOpen((v) => !v)
      }
    />
  )

  return (
    <li
      id={`turn-${anchorId}`}
      data-turn-id={anchorId}
      className="scroll-mt-20 rounded-lg border border-border pb-2"
      style={{ backgroundColor: color }}
    >
      {/* The turn's identity bar — its number + menu on the turn color. No longer a
          fold toggle (turns don't collapse anymore); it stays for identity and as a
          dependable, always-visible home for the menu. It's `sticky` so while you
          read a long turn the bar pins to the top of the viewport (the menu stays in
          reach); it gets pushed off by the next turn's bar (or the previous one's,
          scrolling up). Pinned, it overlaps the turn's content, so it must be opaque
          — it paints the turn color (same as the `<li>` frame, seamless at rest).
          Square bottom (`rounded-t-lg`) so its lower corners sit flush against the
          content below. Those square corners WOULD poke past the frame's rounded
          BOTTOM during the hand-off, so the `<li>`'s `pb-2` ends the bar's sticky
          travel above the curve. z-20 keeps it above the action-row keys it floats
          over. */}
      <div
        style={{ backgroundColor: color }}
        className="sticky top-0 z-20 flex items-center gap-2 rounded-t-lg px-4 py-2"
      >
        <span className="flex-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">
          Turn {number}
        </span>
        {turnMenu}
      </div>

      {/* One neutral reading surface for the whole turn (mirrors the collapsed
          gist's single card), so prose never sits on the turn color — the color is
          chrome now: it rides the sticky bar and shows only as the thin frame the
          `px-2 pt-1.5` here plus the `<li>`'s `pb-2` leave around the card. The `pt`
          keeps a color sliver between the bar's square bottom and the card's rounded
          top (where the hover tint used to collide); the `pb` lives on the `<li>` so
          it doubles as the bar's sticky stop (see the bar comment above). */}
      <div className="px-2 pt-1.5">
        {/* The turn's sections — prompt · rounds · terminal — are flat and
            divider-separated on one surface (no more cards-within-a-card): the
            same shape as the collapsed gist, just expanded. */}
        <div className="divide-y divide-border/50 rounded-md bg-card p-4">
          {/* The prompt — full (compact) markdown, no section label. Its menu floats
              in the top-right corner where the PROMPT header's used to sit; the prose
              gets right padding so it never runs under the menu. */}
          <div
            id={prompt ? `prompt-${prompt.id}` : undefined}
            className="relative scroll-mt-20 py-3 first:pt-0 last:pb-0"
          >
            {prompt && (
              <div className="absolute right-0 top-2">
                <BarMenu
                  label="Prompt actions"
                  anchor={`prompt-${prompt.id}`}
                  source={{ shown: showSource, onToggle: () => setShowSource((v) => !v) }}
                  copySource={() => JSON.stringify(prompt.blocks, null, 2)}
                  annotate={() =>
                    onCompose
                      ? onCompose({ target_kind: 'prompt', anchor_message_id: prompt.id })
                      : setPromptAnnotateOpen((v) => !v)
                  }
                />
              </div>
            )}

            {prompt ? (
              // Through Message (menu-less, headerless — the corner menu above owns
              // source), not inlined blocks: Message carries the data-message-content
              // scope that selection annotation and highlight painting key on, so
              // selecting prompt text grows the "Add note" pill like any section.
              <div className="pr-7">
                <div className="mb-2 flex items-center text-xs text-muted-foreground">
                  <UserChip
                    name={owner.name || owner.username}
                    avatarUrl={owner.avatar_url}
                    className="font-medium"
                  />
                </div>
                <Message
                  message={prompt}
                  conversationId={conversationId}
                  annotations={annotationsFor(annotations, 'message', prompt.id)}
                  toolResults={toolResults}
                  commandStdout={commandStdout[prompt.id]}
                  folded={folded[prompt.id]}
                  bare
                  hideMenu
                  label=""
                  showSource={showSource}
                  onCompose={onCompose}
                />
              </div>
            ) : (
              <p className="text-sm italic text-muted-foreground">
                Opening context before the first prompt.
              </p>
            )}

            {/* The turn's notes and the prompt's notes are distinct targets that
                share this section: the turn menu opens the former, the prompt's
                corner menu the latter. (Inline presentation only — the margin
                carries them on wide screens.) */}
            {!onCompose && (
              <>
                <AnnotationSection
                  annotations={annotationsFor(annotations, 'turn', anchorId)}
                  conversationId={conversationId}
                  target={{ target_kind: 'turn', anchor_message_id: anchorId }}
                  open={turnAnnotateOpen}
                  onOpenChange={setTurnAnnotateOpen}
                />
                {prompt && (
                  <AnnotationSection
                    annotations={annotationsFor(annotations, 'prompt', prompt.id)}
                    conversationId={conversationId}
                    target={{ target_kind: 'prompt', anchor_message_id: prompt.id }}
                    open={promptAnnotateOpen}
                    onOpenChange={setPromptAnnotateOpen}
                  />
                )}
              </>
            )}
          </div>

          {/* The injected continuation summary: machinery, folded behind a flat
              disclosure (same fold bracket as the rounds) so the /compact turn
              stays thin. Open it for the full context (bare Message). */}
          {summary && (
            <div className="py-3 first:pt-0 last:pb-0">
              <div className={`${FOLD_FRAME} ${FOLD_BORDER}`}>
                <button
                  onClick={() => setSummaryOpen((v) => !v)}
                  aria-label={summaryOpen ? 'Collapse summary' : 'Expand summary'}
                  className={rowClass()}
                >
                  {summaryOpen ? (
                    <ChevronDown className="size-3.5 shrink-0 opacity-70" />
                  ) : (
                    <ChevronRight className="size-3.5 shrink-0 opacity-70" />
                  )}
                  <span className="min-w-0 flex-1 truncate text-sm">
                    continuation summary{' '}
                    <span className="text-muted-foreground/70">(compacted)</span>
                  </span>
                </button>
                {summaryOpen && <div className={FOLD_BODY}>{renderMessage(summary, true)}</div>}
              </div>
            </div>
          )}

          {intermediate.length > 0 && (
            // The rounds tree — no section label anymore. Each round folds into a
            // one-line row (n tools + gist); open it to reveal the full narrative +
            // the tool rows it spawned. Long turns elide the middle into "show N more"
            // gaps, split around markers so each keeps a neighbor. py-3 makes it a peer
            // of prompt/terminal. (The expand/collapse-all-rounds control moved to the
            // turn bar's menu.)
            //
            // The rounds section runs a notch smaller than the prompt/terminal — its
            // prose is intermediate work, so it matches the text-xs gist lines it
            // unfurls from (the descendant overrides win on specificity over prose-sm;
            // they don't reach the prompt/terminal, which sit in their own sections).
            // Zeroing the first child's top margin keeps an opened round's first line
            // flush with where its gist sat, and snug paragraph leading matches the
            // gist line height — so a round opens with no vertical jump.
            <div className="space-y-1 py-3 first:pt-0 last:pb-0 [&_.prose]:text-[0.75rem] [&_.prose_p]:leading-snug [&_.prose>*:first-child]:mt-0">
              {roundItems.map((item) =>
                item.kind === 'round' ? renderRound(item.round) : renderGap(item.rounds),
              )}
            </div>
          )}

          {/* The terminal renders bare — flat (compact) markdown on the shared
              surface, no card and no section label, just a slim menu row (empty
              label, headerHighlight off) pinned top-right like the other sections. */}
          {terminal && (
            <div className="py-3 first:pt-0 last:pb-0">
              {renderMessage(terminal, true, false, '')}
            </div>
          )}
        </div>
      </div>
    </li>
  )
}

export default memo(Turn)

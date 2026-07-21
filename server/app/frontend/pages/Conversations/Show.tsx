import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Head, Link, router, usePage } from '@inertiajs/react'
import { MessageSquarePlus } from 'lucide-react'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import AnnotationSection from '@/components/AnnotationSection'
import { isEncryptedThinking } from '@/lib/tools'
import {
  buildCommandPairs,
  buildFoldedIndex,
  buildToolResultIndex,
  hasOwnReason,
  isAbsorbed,
} from '@/lib/message-pairing'
import { parseAnchor, turnMessages } from '@/lib/anchors'
import { annotatedMessageIds, annotationsFor, indexAnnotations } from '@/lib/annotation-index'
import SelectionAnnotator from '@/components/SelectionAnnotator'
import NotesColumn from '@/components/NotesColumn'
import ShareDialog from '@/components/ShareDialog'
import Turn from '@/components/Turn'
import TurnToc from '@/components/TurnToc'
import AppLayout from '@/layouts/AppLayout'
import { targetCandidates } from '@/lib/note-margin'
import { setDraftHighlight } from '@/lib/highlight-registry'
import { useMediaQuery } from '@/lib/use-media-query'
import type {
  Annotation,
  Conversation,
  NoteTarget,
  Round as RoundType,
  Share,
  SharedProps,
  Turn as TurnType,
} from '@/types'

type Props = {
  conversation: Conversation
  turns: TurnType[]
  annotations: Annotation[]
  // Access grants — serialized only to the owner, null for everyone else.
  shares: Share[] | null
}

// A subtle, distinct background tint per turn, cycled by index via the golden
// angle so adjacent turns never collide. Very dark / low-light so foreground
// text and the emerald accents stay readable; the same color lights up the TOC
// entry when its turn is on screen.
function turnColor(index: number): string {
  const hue = Math.round((index * 137.508) % 360)
  return `hsl(${hue} 38% 12%)`
}

export default function Show({ conversation, turns, annotations, shares }: Props) {
  const { current_user } = usePage<SharedProps>().props
  // Compose affordances key on note access, not on being signed in — published
  // conversations are read-only for everyone but the owner and note grantees.
  const canNote = !!current_user && conversation.can_note
  // On wide screens notes live in a third column beside the conversation (the
  // center column is *for the conversation*); narrower, they fall back to the
  // inline sections under their targets. The comment rail outranks the turn
  // TOC as width shrinks — it appears at lg while the TOC rail waits for xl
  // (the "Jump to turn…" disclosure covers the gap). Must match the `lg:`
  // grid breakpoint.
  const marginNotes = useMediaQuery('(min-width: 1024px)')
  // Stable across renders so it's a stable prop for the memoized Turn (and the
  // TOC), not a fresh Map every time activeTurns ticks during a scroll.
  const turnColors = useMemo(
    () => new Map(turns.map((t, i) => [t.anchor_id, turnColor(i)])),
    [turns],
  )
  // Which turns are currently on screen — drives the TOC highlight so you can
  // see your position even color-blind (the lit entries are the visible range).
  const [activeTurns, setActiveTurns] = useState<Set<number>>(new Set())

  useEffect(() => {
    // We recompute the visible set from element rects on a rAF-throttled scroll,
    // rather than accumulating IntersectionObserver deltas: IO heavily throttles
    // (and some browsers defer) its callbacks during a fast scroll, so exit
    // notifications arrive late or get coalesced away — leaving turns lit after
    // they've scrolled off (a delta you never receive can't be undone). Rebuilding
    // the set from truth each frame can't get stuck; worst case is one frame stale.
    const els = Array.from(document.querySelectorAll<HTMLElement>('[data-turn-id]'))
    let raf = 0
    const reconcile = () => {
      raf = 0
      const vh = window.innerHeight
      const next = new Set<number>()
      for (const el of els) {
        const r = el.getBoundingClientRect()
        if (r.bottom > 0 && r.top < vh) next.add(Number(el.dataset.turnId))
      }
      // Keep the old reference when nothing changed so the TOC doesn't re-render.
      setActiveTurns((prev) =>
        prev.size === next.size && [...next].every((id) => prev.has(id)) ? prev : next,
      )
    }
    const onScroll = () => {
      if (!raf) raf = requestAnimationFrame(reconcile)
    }
    reconcile()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll, { passive: true })
    return () => {
      if (raf) cancelAnimationFrame(raf)
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
    }
  }, [turns])
  const [pendingScroll, setPendingScroll] = useState<{
    target: string
    turn: number
  } | null>(null)
  // The marker message a TOC jump asked us to reveal — handed to its turn so the
  // round holding it opens. Cleared once consumed so re-clicking the same marker
  // (after a manual collapse) reveals it again.
  const [revealId, setRevealId] = useState<number | null>(null)

  // Jump from the TOC: reveal the target round (if a marker is buried in a folded
  // round) and scroll once the DOM has settled (deferred via state so the scroll
  // runs after the re-render that opens a just-revealed round). Turns no longer
  // fold, so every `#round-…` / `#turn-…` anchor is already mounted.
  // Stable (useCallback) so it's a steady prop for the memoized TOC without
  // churning it on every scroll-driven re-render.
  const jumpTo = useCallback((anchorId: number, target?: string, reveal?: number) => {
    setRevealId(reveal ?? null)
    setPendingScroll({
      target: target ? `#${target}` : `#turn-${anchorId}`,
      turn: anchorId,
    })
  }, [])

  useEffect(() => {
    if (!pendingScroll) return
    // The precise anchor may not be mounted yet — a tool row inside a round that
    // the reveal is opening in this same commit — so retry a few frames before
    // falling back to the turn top (a marker that's the turn's terminal renders
    // as a plain Message with no `${marker}-id`; the click still gets you there).
    let tries = 0
    let raf = 0
    const attempt = () => {
      const el = document.querySelector(pendingScroll.target)
      if (!el && tries++ < 5) {
        raf = requestAnimationFrame(attempt)
        return
      }
      const target = el ?? document.querySelector(`#turn-${pendingScroll.turn}`)
      target?.scrollIntoView({ behavior: 'smooth', block: 'start' })
      // A one-shot flash so the eye lands with the scroll; classList (not a
      // prop) so the transient effect doesn't churn the memoized Turn tree.
      if (target) {
        target.classList.add('anchor-flash')
        target.addEventListener('animationend', () => target.classList.remove('anchor-flash'), {
          once: true,
        })
      }
      setPendingScroll(null)
      setRevealId(null)
    }
    attempt()
    return () => cancelAnimationFrame(raf)
  }, [pendingScroll])

  // These indices are a pure function of the props, so memoize them — otherwise
  // every activeTurns tick while scrolling recomputed all of them. They also feed
  // the memoized Turn as stable props.
  const annotationIndex = useMemo(() => indexAnnotations(annotations), [annotations])
  const annotatedIds = useMemo(() => annotatedMessageIds(annotations), [annotations])
  const messages = useMemo(() => turns.flatMap(turnMessages), [turns])
  const toolResults = useMemo(() => buildToolResultIndex(messages), [messages])
  const commandPairs = useMemo(() => buildCommandPairs(messages), [messages])
  const folded = useMemo(
    () => buildFoldedIndex(messages, toolResults, commandPairs.foldedByCommandId, annotatedIds),
    [messages, toolResults, commandPairs, annotatedIds],
  )

  // A turn renders the server's rounds minus the messages whose content is
  // already shown inline elsewhere (paired tool results, absorbed command
  // stdout) or is just the model's encrypted chain-of-thought (opaque
  // ciphertext, nothing to read) — unless the message anchors an annotation or
  // is a published snippet. The round *partition* is the server's; only
  // visibility is decided here. Precomputed per turn so each Turn gets a stable
  // rounds array rather than a fresh filter() each render.
  const visibleRounds = useMemo(() => {
    const visible = (turn: TurnType): RoundType[] =>
      turn.rounds
        .map((round) => ({
          anchor_id: round.anchor_id,
          messages: round.messages.filter((m) => {
            // Its own reason to stay overrides every fold rule below.
            if (hasOwnReason(m, annotatedIds)) return true
            if (commandPairs.absorbedIds.has(m.id)) return false
            if (isEncryptedThinking(m)) return false
            return !isAbsorbed(m, toolResults, annotatedIds)
          }),
        }))
        .filter((round) => round.messages.length > 0)
    return new Map(turns.map((t) => [t.anchor_id, visible(t)]))
  }, [turns, toolResults, commandPairs, annotatedIds])

  // Owning turn per message id — how a deep link to a round/tool/message finds
  // the turn that must reveal it.
  const turnByMessageId = useMemo(() => {
    const map = new Map<number, number>()
    for (const turn of turns) for (const m of turnMessages(turn)) map.set(m.id, turn.anchor_id)
    return map
  }, [turns])

  // Owning round per message id — the margin's mid-precision fallback when a
  // note's exact target is folded away (see lib/note-margin targetCandidates).
  const roundByMessageId = useMemo(() => {
    const map = new Map<number, number>()
    for (const turn of turns)
      for (const round of turn.rounds)
        for (const m of round.messages) map.set(m.id, round.anchor_id)
    return map
  }, [turns])

  // ---- The notes margin ----
  // What's being composed (a target descriptor, set by any "Add note"
  // affordance in the transcript) renders as a composer card in the margin,
  // level with its target. One compose at a time; retargeting replaces it.
  const [composing, setComposing] = useState<NoteTarget | null>(null)
  const compose = useCallback((target: NoteTarget) => setComposing(target), [])
  const endCompose = useCallback(() => setComposing(null), [])
  // The margin is the only home for the composer — leaving it (resize) or
  // finishing clears the draft selection highlight along with the state.
  useEffect(() => {
    if (!marginNotes) setComposing(null)
  }, [marginNotes])
  useEffect(() => {
    if (!composing) setDraftHighlight(null)
  }, [composing])
  const onCompose = marginNotes ? compose : undefined

  const ownersOf = useCallback(
    (anchorId: number | null) => ({
      round: anchorId != null ? roundByMessageId.get(anchorId) : undefined,
      turn: anchorId != null ? turnByMessageId.get(anchorId) : undefined,
    }),
    [roundByMessageId, turnByMessageId],
  )
  // Per-note DOM-id candidate chains the margin aligns cards against.
  const noteCandidates = useMemo(
    () =>
      new Map(annotations.map((a) => [a.id, targetCandidates(a, ownersOf(a.anchor_message_id))])),
    [annotations, ownersOf],
  )
  const composeState = useMemo(
    () =>
      composing && {
        target: composing,
        candidates: targetCandidates(composing, ownersOf(composing.anchor_message_id)),
      },
    [composing, ownersOf],
  )

  // Clicking a margin note jumps the transcript to its target — the same
  // reveal/scroll/flash path the TOC and deep links ride.
  const jumpToNote = useCallback(
    (note: Annotation) => {
      if (note.target_kind === 'conversation') {
        document
          .getElementById('conversation')
          ?.scrollIntoView({ behavior: 'smooth', block: 'start' })
        return
      }
      const id = note.anchor_message_id
      if (id == null) return
      const turnAnchor = note.target_kind === 'turn' ? id : turnByMessageId.get(id)
      if (turnAnchor == null) return
      if (note.target_kind === 'turn') jumpTo(turnAnchor)
      else jumpTo(turnAnchor, `${note.target_kind}-${id}`, id)
    },
    [turnByMessageId, jumpTo],
  )

  // The center column, observed by the margin so cards track fold reflows.
  const centerRef = useRef<HTMLDivElement>(null)
  const showMargin = marginNotes && (annotations.length > 0 || canNote)

  // Honor an entity address arriving in the URL fragment (#turn-12, #round-34,
  // #tool-56, #message-78, or a marker) — on first paint and on later hash
  // changes: scroll to it, unfolding the round/tool that buries it. The same
  // jumpTo path the TOC uses, so deep links and TOC clicks can't drift apart.
  useEffect(() => {
    const followHash = () => {
      const parsed = parseAnchor(window.location.hash)
      if (!parsed) return
      const turnAnchor =
        parsed.kind === 'turn' ? parsed.messageId : turnByMessageId.get(parsed.messageId)
      if (turnAnchor == null) return
      jumpTo(
        turnAnchor,
        parsed.kind === 'turn' ? undefined : window.location.hash.slice(1),
        parsed.kind === 'turn' ? undefined : parsed.messageId,
      )
    }
    followHash()
    window.addEventListener('hashchange', followHash)
    return () => window.removeEventListener('hashchange', followHash)
  }, [turnByMessageId, jumpTo])
  const meta: [string, string | null][] = [
    ['source', conversation.source],
    ['cwd', conversation.original_cwd],
    ['branch', conversation.git_branch],
    ['version', conversation.agent_version],
  ]

  function togglePublish() {
    router.patch(`/conversations/${conversation.id}/publish`, {}, { preserveScroll: true })
  }

  return (
    <AppLayout mainClassName={showMargin ? 'max-w-6xl xl:max-w-[88rem]' : 'max-w-6xl'}>
      <Head title={conversation.title} />
      <SelectionAnnotator conversationId={conversation.id} onCompose={onCompose} />

      <details className={`mb-4 ${showMargin ? 'xl:hidden' : 'lg:hidden'}`}>
        <summary className="cursor-pointer text-sm text-muted-foreground">Jump to turn…</summary>
        <div className="mt-3">
          <TurnToc
            turns={turns}
            colors={turnColors}
            active={activeTurns}
            projectRoot={conversation.original_cwd}
            onJump={jumpTo}
          />
        </div>
      </details>

      <div
        className={
          // With the margin up, lg gets center + comment rail and the TOC rail
          // joins at xl; without it, lg gets TOC + center as ever.
          showMargin
            ? 'lg:grid lg:grid-cols-[minmax(0,1fr)_19rem] lg:gap-8 xl:grid-cols-[14rem_minmax(0,1fr)_19rem]'
            : 'lg:grid lg:grid-cols-[14rem_minmax(0,1fr)] lg:gap-8'
        }
      >
        <aside className={showMargin ? 'hidden xl:block' : 'hidden lg:block'}>
          <div className="sticky top-6">
            <TurnToc
              turns={turns}
              colors={turnColors}
              active={activeTurns}
              projectRoot={conversation.original_cwd}
              onJump={jumpTo}
              scrollable
            />
          </div>
        </aside>

        <div className="min-w-0" ref={centerRef}>
          <header id="conversation" className="mb-4 scroll-mt-20 border-b border-border pb-4">
            <h1 className="text-2xl font-bold">{conversation.title}</h1>
            {conversation.parent && (
              <p className="mt-1 text-sm text-muted-foreground">
                part of{' '}
                <Link href={`/conversations/${conversation.parent.id}`} className="hover:underline">
                  {conversation.parent.title ?? `conversation #${conversation.parent.id}`}
                </Link>
              </p>
            )}
            <p className="mt-1 flex items-center gap-2 text-sm text-muted-foreground">
              {conversation.status} · {turns.length} turns
              {conversation.published && <Badge variant="secondary">published</Badge>}
            </p>

            <dl className="mt-2 grid grid-cols-[max-content_minmax(0,1fr)] gap-x-3 text-xs text-muted-foreground">
              {meta.map(([label, value]) =>
                value ? (
                  <div key={label} className="contents">
                    <dt className="font-mono">{label}</dt>
                    <dd className="break-all">{value}</dd>
                  </div>
                ) : null,
              )}
            </dl>

            {(conversation.can_manage || (canNote && marginNotes)) && (
              <div className="mt-3 flex gap-2">
                {canNote && marginNotes && (
                  // The margin's conversation-level trigger — the inline section
                  // below carries its own when notes render inline instead.
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={() =>
                      compose({
                        target_kind: 'conversation',
                        anchor_message_id: null,
                      })
                    }
                  >
                    <MessageSquarePlus /> Add note
                  </Button>
                )}
                {conversation.can_manage && (
                  <>
                    <ShareDialog conversationId={conversation.id} shares={shares ?? []} />
                    <Button size="sm" onClick={togglePublish}>
                      {conversation.published ? 'Unpublish' : 'Publish whole conversation'}
                    </Button>
                    <AlertDialog>
                      <AlertDialogTrigger asChild>
                        <Button size="sm" variant="destructive">
                          Delete
                        </Button>
                      </AlertDialogTrigger>
                      <AlertDialogContent>
                        <AlertDialogHeader>
                          <AlertDialogTitle>Delete this conversation?</AlertDialogTitle>
                          <AlertDialogDescription>
                            This permanently removes the conversation and its {turns.length} turns.
                          </AlertDialogDescription>
                        </AlertDialogHeader>
                        <AlertDialogFooter>
                          <AlertDialogCancel>Cancel</AlertDialogCancel>
                          <AlertDialogAction
                            onClick={() => router.delete(`/conversations/${conversation.id}`)}
                          >
                            Delete
                          </AlertDialogAction>
                        </AlertDialogFooter>
                      </AlertDialogContent>
                    </AlertDialog>
                  </>
                )}
              </div>
            )}
          </header>

          {conversation.children && conversation.children.length > 0 && (
            <section className="mb-4 border-b border-border pb-4">
              <h2 className="text-sm font-semibold text-muted-foreground">Subagent transcripts</h2>
              <ul className="mt-2 divide-y divide-border">
                {conversation.children.map((child) => (
                  <li key={child.id} className="py-1.5">
                    <Link href={`/conversations/${child.id}`} className="text-sm hover:underline">
                      {child.title ?? child.session_id}
                    </Link>
                  </li>
                ))}
              </ul>
            </section>
          )}

          {!marginNotes && (
            <AnnotationSection
              annotations={annotationsFor(annotationIndex, 'conversation', null)}
              conversationId={conversation.id}
              target={{ target_kind: 'conversation', anchor_message_id: null }}
            />
          )}

          {(conversation.status === 'pending' || conversation.status === 'processing') && (
            <p className="mt-4 text-sm text-muted-foreground">
              Import in progress — refresh in a moment.
            </p>
          )}

          <ol className="mt-4 space-y-3">
            {turns.map((turn, i) => (
              <Turn
                key={turn.anchor_id}
                anchorId={turn.anchor_id}
                number={i + 1}
                prompt={turn.prompt}
                rounds={visibleRounds.get(turn.anchor_id) ?? []}
                conversationId={conversation.id}
                annotations={annotationIndex}
                toolResults={toolResults}
                commandStdout={commandPairs.stdoutByMessageId}
                folded={folded}
                reveal={
                  revealId != null && turnByMessageId.get(revealId) === turn.anchor_id
                    ? revealId
                    : null
                }
                color={turnColors.get(turn.anchor_id) ?? 'transparent'}
                projectRoot={conversation.original_cwd}
                owner={conversation.owner}
                onCompose={onCompose}
              />
            ))}
          </ol>
        </div>

        {showMargin && (
          <aside className="hidden lg:block">
            <NotesColumn
              notes={annotations}
              conversationId={conversation.id}
              candidates={noteCandidates}
              composing={composeState}
              onComposeEnd={endCompose}
              onSelect={jumpToNote}
              contentRef={centerRef}
            />
          </aside>
        )}
      </div>
    </AppLayout>
  )
}

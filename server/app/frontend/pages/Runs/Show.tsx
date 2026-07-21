import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Head, Link } from '@inertiajs/react'
import AppLayout from '@/layouts/AppLayout'
import Message from '@/components/Message'
import { buildToolResultIndex } from '@/lib/message-pairing'
import { initialState, mergedMessages, reduce } from '@/lib/sse-reducer'
import type { LiveMessage, SSEEvent } from '@/lib/sse-reducer'
import type { Message as MessageType, Run } from '@/types'

type Props = { run: Run }

// Adapts a LiveMessage to the Message component's expected shape.
// Uses the array index as the numeric id since live messages have no DB id.
function toLegacyMessage(msg: LiveMessage, index: number): MessageType {
  return {
    id: index,
    role: msg.role,
    model: msg.model,
    position: index,
    published: false,
    blocks: msg.blocks,
    can_publish: false,
  }
}

export default function Show({ run }: Props) {
  const [state, setState] = useState(initialState)

  // Tracks the live SSE connection across reconnects (mount + refocus) so a
  // re-sync can always tear down whatever is currently open before starting
  // the next one — never two subscriptions alive at once.
  const esRef = useRef<EventSource | null>(null)
  // Mirrors `state` for the visibilitychange handler below, which closes over
  // a stale `state` otherwise (it's registered once, not on every state change).
  const stateRef = useRef(state)
  stateRef.current = state

  const connect = useCallback(() => {
    esRef.current?.close()
    // Fresh run state: a reconnect replays the run from the top (Redis backlog
    // or db_replay), so stale accumulated messages must not linger underneath it.
    setState(initialState)

    let done = false
    const es = new EventSource(`/runs/${run.id}/stream`)

    es.onmessage = (e: MessageEvent) => {
      try {
        const event = JSON.parse(e.data as string) as SSEEvent
        setState((prev) => reduce(prev, event, e.lastEventId || undefined))
        if (event.type === 'run_complete' && !done) {
          done = true
          es.close()
        }
      } catch {
        // ignore malformed events
      }
    }

    // Allow auto-reconnect on transient errors; only force-close once run_complete seen.
    es.onerror = () => {
      if (done) es.close()
    }

    esRef.current = es
  }, [run.id])

  useEffect(() => {
    connect()
    return () => esRef.current?.close()
  }, [connect])

  // A backgrounded tab's EventSource can die silently, leaving stale painted
  // "live" state with no subscription and no recovery short of a manual
  // reload. On refocus, re-sync automatically — unless the run already
  // finished, in which case there's nothing left to stream.
  useEffect(() => {
    const onVisibilityChange = () => {
      if (document.visibilityState !== 'visible') return
      if (stateRef.current.status === 'complete') return
      connect()
    }

    document.addEventListener('visibilitychange', onVisibilityChange)
    return () => document.removeEventListener('visibilitychange', onVisibilityChange)
  }, [connect])

  const messages = mergedMessages(state)

  const legacyMessages = useMemo(() => messages.map(toLegacyMessage), [messages])

  const toolResults = useMemo(() => buildToolResultIndex(legacyMessages), [legacyMessages])

  // The opening prompt never streams over SSE (claude/opencode don't emit it,
  // and pi's copy — now that it's persisted, see Normalizer::Pi — arrives via
  // the replayed transcript, not this live view). It only reaches the client
  // through job.spec["prompt"], owner-gated the same way as job.id/status.
  const promptMessage: MessageType | null = run.job?.prompt
    ? {
        id: -1,
        role: 'user',
        model: null,
        position: -1,
        published: false,
        blocks: [{ type: 'text', text: run.job.prompt }],
        can_publish: false,
      }
    : null

  return (
    <AppLayout>
      <Head title={`Run #${run.id}`} />

      <header className="mb-4 border-b border-border pb-4">
        <h1 className="text-2xl font-bold">Run #{run.id}</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          {run.status}
          {run.published && ' · published'}
          {state.status === 'live' && ' · streaming'}
        </p>

        <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 text-sm sm:grid-cols-4">
          {run.harness && (
            <div>
              <dt className="text-muted-foreground">Harness</dt>
              <dd>{run.harness}</dd>
            </div>
          )}
          {run.model && (
            <div>
              <dt className="text-muted-foreground">Model</dt>
              <dd>{run.model}</dd>
            </div>
          )}
          {run.role && (
            <div>
              <dt className="text-muted-foreground">Role</dt>
              <dd>{run.role}</dd>
            </div>
          )}
          {run.job && (
            <div>
              <dt className="text-muted-foreground">Job</dt>
              <dd>
                <Link href={`/jobs/${run.job.id}`} className="underline underline-offset-2">
                  #{run.job.id}
                </Link>
                {' · '}
                {run.job.status}
              </dd>
            </div>
          )}
        </dl>

      </header>

      {state.status === 'pending' && (
        <p className="text-sm text-muted-foreground">Connecting…</p>
      )}

      <ol className="mt-4 space-y-3">
        {promptMessage && (
          <li>
            <Message message={promptMessage} conversationId={0} hideMenu />
          </li>
        )}
        {legacyMessages.map((msg, i) => (
          <li key={i}>
            <Message message={msg} conversationId={0} toolResults={toolResults} hideMenu />
          </li>
        ))}
      </ol>
    </AppLayout>
  )
}

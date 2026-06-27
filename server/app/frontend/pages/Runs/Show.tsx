import { useEffect, useMemo, useState } from 'react'
import { Head } from '@inertiajs/react'
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

  useEffect(() => {
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

    return () => {
      done = true
      es.close()
    }
  }, [run.id])

  const messages = mergedMessages(state)

  const legacyMessages = useMemo(() => messages.map(toLegacyMessage), [messages])

  const toolResults = useMemo(() => buildToolResultIndex(legacyMessages), [legacyMessages])

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
      </header>

      {state.status === 'pending' && (
        <p className="text-sm text-muted-foreground">Connecting…</p>
      )}

      <ol className="mt-4 space-y-3">
        {legacyMessages.map((msg, i) => (
          <li key={i}>
            <Message message={msg} conversationId={0} toolResults={toolResults} hideMenu />
          </li>
        ))}
      </ol>
    </AppLayout>
  )
}

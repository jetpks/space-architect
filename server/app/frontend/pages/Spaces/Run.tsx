import { useMemo } from 'react'
import { Head } from '@inertiajs/react'
import AppLayout from '@/layouts/AppLayout'
import TurnComponent from '@/components/Turn'
import {
  buildCommandPairs,
  buildFoldedIndex,
  buildToolResultIndex,
  isAbsorbed,
} from '@/lib/message-pairing'
import { isEncryptedThinking } from '@/lib/tools'
import type {
  Annotation,
  Round as RoundType,
  SpaceRunDetail,
  Turn as TurnType,
} from '@/types'

type Props = {
  space: { id: number; slug: string; title: string }
  run: SpaceRunDetail
  turns: TurnType[]
}

export default function Run({ space, run, turns }: Props) {
  const allMessages = useMemo(
    () =>
      turns.flatMap((t) => [
        ...(t.prompt ? [t.prompt] : []),
        ...t.rounds.flatMap((r) => r.messages),
      ]),
    [turns],
  )

  const toolResults = useMemo(() => buildToolResultIndex(allMessages), [allMessages])
  const commandPairs = useMemo(() => buildCommandPairs(allMessages), [allMessages])
  const emptyAnnotatedIds = useMemo(() => new Set<number>(), [])

  const folded = useMemo(
    () =>
      buildFoldedIndex(
        allMessages,
        toolResults,
        commandPairs.foldedByCommandId,
        emptyAnnotatedIds,
      ),
    [allMessages, toolResults, commandPairs, emptyAnnotatedIds],
  )

  const visibleRounds = useMemo(() => {
    const visible = (turn: TurnType): RoundType[] =>
      turn.rounds
        .map((round) => ({
          anchor_id: round.anchor_id,
          messages: round.messages.filter((m) => {
            if (isEncryptedThinking(m)) return false
            return !isAbsorbed(m, toolResults, emptyAnnotatedIds)
          }),
        }))
        .filter((round) => round.messages.length > 0)
    return new Map(turns.map((t) => [t.anchor_id, visible(t)]))
  }, [turns, toolResults, emptyAnnotatedIds])

  const emptyAnnotations = useMemo(() => new Map<string, Annotation[]>(), [])

  const owner = useMemo(
    () => ({ username: run.producer ?? run.role, name: null, avatar_url: null }),
    [run.producer, run.role],
  )

  return (
    <AppLayout>
      <Head title={`Run #${run.id} — ${space.title}`} />

      <header className="mb-4 border-b border-border pb-4">
        <h1 className="text-2xl font-bold">
          {run.lane} / {run.role} — Run #{run.id}
        </h1>
        <p className="mt-1 text-sm text-muted-foreground">
          {space.title} · {run.status}
        </p>
      </header>

      {turns.length === 0 && (
        <p className="text-sm text-muted-foreground">No transcript content.</p>
      )}

      <ol className="mt-4 space-y-3">
        {turns.map((turn, i) => (
          <TurnComponent
            key={turn.anchor_id}
            anchorId={turn.anchor_id}
            number={i + 1}
            prompt={turn.prompt}
            rounds={visibleRounds.get(turn.anchor_id) ?? []}
            conversationId={run.conversation_id ?? 0}
            annotations={emptyAnnotations}
            toolResults={toolResults}
            commandStdout={commandPairs.stdoutByMessageId}
            folded={folded}
            reveal={null}
            color="transparent"
            projectRoot={null}
            owner={owner}
          />
        ))}
      </ol>
    </AppLayout>
  )
}

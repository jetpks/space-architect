import type { Message, Turn } from '@/types'

// The canonical entity-address vocabulary, shared by URL fragments, the
// entities API, and the DOM ids the transcript hangs on its rows. One parser
// so a pasted deep link, a TOC jump, and a copied permalink all mean the same
// thing. Marker fragments (decision-/memory-/commit-) are jump targets the TOC
// already emits; they address a message by id like the rest.
export type AnchorKind =
  | 'turn'
  | 'prompt'
  | 'round'
  | 'tool'
  | 'message'
  | 'decision'
  | 'memory'
  | 'commit'

export type ParsedAnchor = { kind: AnchorKind; messageId: number }

// `tool-<id>-<tool_use_id>` (the long form the backend accepts) parses too; the
// message id is all the DOM needs.
const ANCHOR = /^#?(turn|prompt|round|tool|message|decision|memory|commit)-(\d+)(?:-[\w-]+)?$/

export function parseAnchor(hash: string): ParsedAnchor | null {
  const match = ANCHOR.exec(hash)
  if (!match) return null
  return { kind: match[1] as AnchorKind, messageId: Number(match[2]) }
}

// A turn's members in stream order — the prompt, then every round's messages.
export function turnMessages(turn: Turn): Message[] {
  const rest = turn.rounds.flatMap((r) => r.messages)
  return turn.prompt ? [turn.prompt, ...rest] : rest
}

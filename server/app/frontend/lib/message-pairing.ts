import type {
  Message,
  TextBlock,
  ToolResultBlock,
  ToolResultIndex,
  ToolUseBlock,
} from '@/types'

// The cross-message coupling that turns the raw, linear message stream into the
// rendered transcript: a tool_use is answered by a tool_result in a *later*
// user-role turn, and a slash command's stdout lands in the adjacent turn. These
// pure functions pair those up (and decide which now-folded turns drop out of the
// top-level list) so the page component can stay about state and layout. Kept
// here, free of React, so the pairing rules — the trickiest, most
// correctness-sensitive logic in the frontend — can be unit-tested directly.

function messageText(m: Message): string {
  return m.blocks
    .filter((b) => b.type === 'text')
    .map((b) => (b as TextBlock).text ?? '')
    .join('\n')
}

// The stdout a slash-command's *following* message carries, or null when the
// message isn't a bare stdout half (e.g. it opens its own command).
function commandStdoutText(m: Message): string | null {
  const text = messageText(m)
  if (/<command-name>/.test(text)) return null
  return text.match(/<local-command-stdout>([\s\S]*?)<\/local-command-stdout>/)?.[1]?.trim() ?? null
}

// Slash-command turns store the command and its output in two adjacent user-role
// messages: one with <command-name>, the next with <local-command-stdout>. Pair
// them so they render as one block, and drop the now-absorbed stdout turn from the
// top-level list.
export function buildCommandPairs(messages: Message[]) {
  const stdoutByMessageId: Record<number, string> = {}
  const absorbedIds = new Set<number>()
  const foldedByCommandId: Record<number, Message[]> = {}
  for (let i = 0; i < messages.length - 1; i++) {
    if (!/<command-name>/.test(messageText(messages[i]))) continue
    const stdout = commandStdoutText(messages[i + 1])
    if (stdout === null) continue
    stdoutByMessageId[messages[i].id] = stdout
    absorbedIds.add(messages[i + 1].id)
    foldedByCommandId[messages[i].id] = [messages[i + 1]]
  }
  return { stdoutByMessageId, absorbedIds, foldedByCommandId }
}

// Pair each tool_use with the tool_result that answers it (the result lands in a
// later user-role turn, keyed by tool_use_id). We render the result inline under
// its call, so turns made up entirely of already-paired results are dropped from
// the top-level list — they'd otherwise show as empty "user" turns.
export function buildToolResultIndex(messages: Message[]): ToolResultIndex {
  const byUseId: Record<string, ToolResultBlock> = {}
  const useIds = new Set<string>()
  for (const m of messages) {
    for (const b of m.blocks) {
      if (b.type === 'tool_use' && (b as ToolUseBlock).id) {
        useIds.add((b as ToolUseBlock).id!)
      } else if (b.type === 'tool_result' && (b as ToolResultBlock).tool_use_id) {
        byUseId[(b as ToolResultBlock).tool_use_id!] = b as ToolResultBlock
      }
    }
  }
  return { byUseId, useIds }
}

// A turn carries its own reason to stay even when its content is also rendered
// elsewhere (a folded tool result, absorbed command stdout): a reader annotated
// it (annotatedIds — the anchors of every annotation, built in Show), or it's
// published as a standalone snippet. Dropping it would lose that, so every
// place that would otherwise fold a turn away checks this first.
export function hasOwnReason(message: Message, annotatedIds: Set<number>): boolean {
  return annotatedIds.has(message.id) || message.published
}

export function isAbsorbed(
  message: Message,
  index: ToolResultIndex,
  annotatedIds: Set<number>,
): boolean {
  // Only drop plain result-only plumbing turns; one with its own reason to stay
  // is never absorbed.
  return (
    !hasOwnReason(message, annotatedIds) &&
    message.blocks.length > 0 &&
    message.blocks.every(
      (b) =>
        b.type === 'tool_result' &&
        !!(b as ToolResultBlock).tool_use_id &&
        index.useIds.has((b as ToolResultBlock).tool_use_id!),
    )
  )
}

// Some turns are folded into another turn's rendering: a tool_result lands under
// the tool_use that called it, and a slash command's stdout lands in the command
// turn. Map each owner turn to the raw turns folded into it, so the source view
// can present them too — the source stays obtainable without a separate toggle.
export function buildFoldedIndex(
  messages: Message[],
  toolResults: ToolResultIndex,
  foldedByCommandId: Record<number, Message[]>,
  annotatedIds: Set<number>,
): Record<number, Message[]> {
  const ownerByUseId: Record<string, number> = {}
  for (const m of messages)
    for (const b of m.blocks)
      if (b.type === 'tool_use' && (b as ToolUseBlock).id)
        ownerByUseId[(b as ToolUseBlock).id!] = m.id

  const byOwner: Record<number, Message[]> = { ...foldedByCommandId }
  for (const m of messages) {
    if (!isAbsorbed(m, toolResults, annotatedIds)) continue
    const owners = new Set<number>()
    for (const b of m.blocks) {
      const useId = (b as ToolResultBlock).tool_use_id
      if (b.type === 'tool_result' && useId && ownerByUseId[useId] != null)
        owners.add(ownerByUseId[useId])
    }
    owners.forEach((id) => ((byOwner[id] ??= []).push(m)))
  }
  return byOwner
}

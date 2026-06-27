import type { TargetKind } from '@/types'

// The notes margin: pure positioning logic for the third column. Each note
// wants to sit level with its target in the transcript; when neighbors would
// overlap, later notes are pushed down — a single top-to-bottom sweep, the
// classic comment-rail layout.

export type NoteBox = {
  key: string
  // Where the note's target sits, in the margin container's coordinate space.
  anchorTop: number
  // The rendered card's height, measured before the sweep.
  height: number
}

// Assign each box a top: at its anchor when free, else just below the box
// above. Sorted by anchor (stable, so notes on the same target keep creation
// order); the result never reorders vertically relative to the transcript.
export function layoutNotes(boxes: NoteBox[], gap = 8): Map<string, number> {
  const tops = new Map<string, number>()
  let bottom = -Infinity
  for (const box of [...boxes].sort((a, b) => a.anchorTop - b.anchorTop)) {
    const top = Math.max(box.anchorTop, bottom + gap)
    tops.set(box.key, top)
    bottom = top + box.height
  }
  return tops
}

// A note's target can be folded away — an elided round, a message inside a
// closed tool row — so alignment uses a candidate chain: the most precise DOM
// id first, falling back through the enclosing round and turn, which always
// render. Tool rows swap their id for a marker id (`decision-`/`memory-`/
// `commit-`) when marked, so those variants ride in the chain too.
export type TargetOwners = { round?: number; turn?: number }

export function targetCandidates(
  target: { target_kind: TargetKind; anchor_message_id: number | null },
  owners: TargetOwners = {},
): string[] {
  const id = target.anchor_message_id
  const round = owners.round != null ? [`round-${owners.round}`] : []
  const turn = owners.turn != null ? [`turn-${owners.turn}`] : []
  const toolIds = [`tool-${id}`, `decision-${id}`, `memory-${id}`, `commit-${id}`]
  switch (target.target_kind) {
    case 'conversation':
      return ['conversation']
    case 'turn':
      return [`turn-${id}`]
    case 'prompt':
      return [`prompt-${id}`, ...turn]
    case 'round':
      return [`round-${id}`, ...turn]
    case 'tool':
      return [...toolIds, ...round, ...turn]
    case 'message':
      return [`message-${id}`, ...toolIds, ...round, ...turn]
  }
}

import type { Annotation, TargetKind } from '@/types'

// Annotations arrive as one flat conversation-level list, each carrying its
// target descriptor; these helpers distribute them. One Map keyed by
// (kind, anchor) — built once in Show and threaded down — so every component
// looks its notes up by the same key its DOM anchor uses, and the memoized
// Turn tree keeps a stable prop.

export function targetKey(kind: TargetKind, anchorMessageId: number | null): string {
  return `${kind}:${anchorMessageId ?? ''}`
}

export function indexAnnotations(annotations: Annotation[]): Map<string, Annotation[]> {
  const map = new Map<string, Annotation[]>()
  for (const annotation of annotations) {
    const key = targetKey(annotation.target_kind, annotation.anchor_message_id)
    const list = map.get(key)
    if (list) list.push(annotation)
    else map.set(key, [annotation])
  }
  return map
}

export function annotationsFor(
  index: Map<string, Annotation[]>,
  kind: TargetKind,
  anchorMessageId: number | null,
): Annotation[] {
  return index.get(targetKey(kind, anchorMessageId)) ?? []
}

// Message ids referenced by any annotation — an annotated message (or one
// anchoring an annotated round/tool/turn) carries its own reason to stay
// visible when folding would otherwise absorb it.
export function annotatedMessageIds(annotations: Annotation[]): Set<number> {
  const ids = new Set<number>()
  for (const annotation of annotations) {
    if (annotation.anchor_message_id != null) ids.add(annotation.anchor_message_id)
  }
  return ids
}

// The message-targeted annotations that carry a text-range selector — the ones
// painted as highlights inside the message body.
export function rangeAnnotationsFor(
  index: Map<string, Annotation[]>,
  messageId: number,
): Annotation[] {
  return annotationsFor(index, 'message', messageId).filter((a) => a.selector)
}

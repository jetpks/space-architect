import { describe, expect, it } from 'vitest'
import {
  annotatedMessageIds,
  annotationsFor,
  indexAnnotations,
  rangeAnnotationsFor,
} from './annotation-index'
import type { Annotation, Selector, TargetKind } from '@/types'

let nextId = 0
function note(
  target_kind: TargetKind,
  anchor_message_id: number | null,
  selector: Selector | null = null,
): Annotation {
  return {
    id: ++nextId,
    body: 'note',
    author: 'eric',
    author_avatar_url: null,
    can_delete: true,
    target_kind,
    anchor_message_id,
    tool_use_id: null,
    selector,
  }
}

const selector: Selector = { exact: 'hi', prefix: '', suffix: '', position: 0 }

describe('indexAnnotations', () => {
  it('groups by kind and anchor, preserving order', () => {
    const a = note('round', 5)
    const b = note('round', 5)
    const c = note('tool', 5)
    const d = note('conversation', null)
    const index = indexAnnotations([a, b, c, d])

    expect(annotationsFor(index, 'round', 5)).toEqual([a, b])
    expect(annotationsFor(index, 'tool', 5)).toEqual([c])
    expect(annotationsFor(index, 'conversation', null)).toEqual([d])
    expect(annotationsFor(index, 'message', 5)).toEqual([])
  })
})

describe('annotatedMessageIds', () => {
  it('collects anchors across kinds, skipping conversation notes', () => {
    const ids = annotatedMessageIds([
      note('message', 1),
      note('round', 2),
      note('tool', 3),
      note('conversation', null),
    ])
    expect(ids).toEqual(new Set([1, 2, 3]))
  })
})

describe('rangeAnnotationsFor', () => {
  it('returns only message notes carrying a selector', () => {
    const plain = note('message', 7)
    const range = note('message', 7, selector)
    const index = indexAnnotations([plain, range, note('round', 7, null)])

    expect(rangeAnnotationsFor(index, 7)).toEqual([range])
  })
})

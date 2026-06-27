import { describe, expect, it } from 'vitest'
import { layoutNotes, targetCandidates } from './note-margin'

describe('layoutNotes', () => {
  it('places non-overlapping notes at their anchors', () => {
    const tops = layoutNotes([
      { key: 'a', anchorTop: 0, height: 40 },
      { key: 'b', anchorTop: 100, height: 40 },
    ])
    expect(tops.get('a')).toBe(0)
    expect(tops.get('b')).toBe(100)
  })

  it('pushes an overlapping note below its predecessor', () => {
    const tops = layoutNotes(
      [
        { key: 'a', anchorTop: 0, height: 60 },
        { key: 'b', anchorTop: 30, height: 40 },
      ],
      8,
    )
    expect(tops.get('a')).toBe(0)
    expect(tops.get('b')).toBe(68)
  })

  it('cascades pushes through a run of stacked notes', () => {
    const tops = layoutNotes(
      [
        { key: 'a', anchorTop: 0, height: 50 },
        { key: 'b', anchorTop: 10, height: 50 },
        { key: 'c', anchorTop: 20, height: 50 },
      ],
      10,
    )
    expect(tops.get('a')).toBe(0)
    expect(tops.get('b')).toBe(60)
    expect(tops.get('c')).toBe(120)
  })

  it('keeps input order for notes sharing an anchor', () => {
    const tops = layoutNotes(
      [
        { key: 'first', anchorTop: 50, height: 20 },
        { key: 'second', anchorTop: 50, height: 20 },
      ],
      8,
    )
    expect(tops.get('first')).toBe(50)
    expect(tops.get('second')).toBe(78)
  })

  it('sorts by anchor regardless of input order', () => {
    const tops = layoutNotes([
      { key: 'low', anchorTop: 200, height: 30 },
      { key: 'high', anchorTop: 0, height: 30 },
    ])
    expect(tops.get('high')).toBe(0)
    expect(tops.get('low')).toBe(200)
  })
})

describe('targetCandidates', () => {
  const owners = { round: 7, turn: 3 }

  it('addresses the conversation header', () => {
    expect(targetCandidates({ target_kind: 'conversation', anchor_message_id: null })).toEqual([
      'conversation',
    ])
  })

  it('addresses a turn directly with no fallback', () => {
    expect(targetCandidates({ target_kind: 'turn', anchor_message_id: 3 }, owners)).toEqual([
      'turn-3',
    ])
  })

  it('falls a prompt back to its turn', () => {
    expect(targetCandidates({ target_kind: 'prompt', anchor_message_id: 3 }, owners)).toEqual([
      'prompt-3',
      'turn-3',
    ])
  })

  it('falls a round back to its turn', () => {
    expect(targetCandidates({ target_kind: 'round', anchor_message_id: 7 }, owners)).toEqual([
      'round-7',
      'turn-3',
    ])
  })

  it('tries marker ids for a tool row, then the enclosing round and turn', () => {
    expect(targetCandidates({ target_kind: 'tool', anchor_message_id: 9 }, owners)).toEqual([
      'tool-9',
      'decision-9',
      'memory-9',
      'commit-9',
      'round-7',
      'turn-3',
    ])
  })

  it('tries the message id first, then the tool row that may contain it', () => {
    expect(
      targetCandidates({ target_kind: 'message', anchor_message_id: 9 }, owners)[0],
    ).toBe('message-9')
    expect(targetCandidates({ target_kind: 'message', anchor_message_id: 9 }, owners)).toContain(
      'round-7',
    )
  })

  it('omits fallbacks when owners are unknown', () => {
    expect(targetCandidates({ target_kind: 'round', anchor_message_id: 7 })).toEqual(['round-7'])
  })
})

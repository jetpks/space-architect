import { describe, expect, it } from 'vitest'
import { parseAnchor, turnMessages } from './anchors'
import type { Message, Turn } from '@/types'

describe('parseAnchor', () => {
  it('parses every entity and marker kind, with or without the #', () => {
    expect(parseAnchor('#turn-12')).toEqual({ kind: 'turn', messageId: 12 })
    expect(parseAnchor('prompt-3')).toEqual({ kind: 'prompt', messageId: 3 })
    expect(parseAnchor('#round-34')).toEqual({ kind: 'round', messageId: 34 })
    expect(parseAnchor('#tool-56')).toEqual({ kind: 'tool', messageId: 56 })
    expect(parseAnchor('#message-78')).toEqual({ kind: 'message', messageId: 78 })
    expect(parseAnchor('#decision-90')).toEqual({ kind: 'decision', messageId: 90 })
    expect(parseAnchor('#memory-9')).toEqual({ kind: 'memory', messageId: 9 })
    expect(parseAnchor('#commit-5')).toEqual({ kind: 'commit', messageId: 5 })
  })

  it('accepts the long tool form, keeping the message id', () => {
    expect(parseAnchor('#tool-56-toolu_abc123')).toEqual({ kind: 'tool', messageId: 56 })
  })

  it('rejects garbage', () => {
    for (const bad of ['', '#', '#turn-', '#bogus-1', '#turn-x', 'turn12', '#conversation']) {
      expect(parseAnchor(bad), bad).toBeNull()
    }
  })
})

describe('turnMessages', () => {
  const msg = (id: number): Message => ({
    id,
    role: 'assistant',
    model: null,
    position: id,
    published: false,
    blocks: [],
    can_publish: false,
  })

  it('flattens prompt then rounds in order', () => {
    const turn: Turn = {
      anchor_id: 1,
      prompt: msg(1),
      rounds: [
        { anchor_id: 2, messages: [msg(2), msg(3)] },
        { anchor_id: 4, messages: [msg(4)] },
      ],
    }
    expect(turnMessages(turn).map((m) => m.id)).toEqual([1, 2, 3, 4])
  })

  it('handles a prompt-less preamble turn', () => {
    const turn: Turn = { anchor_id: 2, prompt: null, rounds: [{ anchor_id: 2, messages: [msg(2)] }] }
    expect(turnMessages(turn).map((m) => m.id)).toEqual([2])
  })
})

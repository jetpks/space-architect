import { describe, expect, it } from 'vitest'
import {
  buildCommandPairs,
  buildFoldedIndex,
  buildToolResultIndex,
  hasOwnReason,
  isAbsorbed,
} from '@/lib/message-pairing'
import type { Block, Message } from '@/types'

// --- fixtures -------------------------------------------------------------

let nextId = 1
function msg(blocks: Block[], extra: Partial<Message> = {}): Message {
  const id = nextId++
  return {
    id,
    role: 'assistant',
    model: null,
    position: id,
    published: false,
    blocks,
    can_publish: false,
    ...extra,
  }
}

const text = (t: string): Block => ({ type: 'text', text: t })
const use = (id: string): Block => ({ type: 'tool_use', id, name: 'Bash', input: {} })
const result = (toolUseId: string): Block => ({ type: 'tool_result', tool_use_id: toolUseId, content: 'ok' })
const none = new Set<number>()

// --- buildToolResultIndex -------------------------------------------------

describe('buildToolResultIndex', () => {
  it('pairs a tool_result to the tool_use it answers, across messages', () => {
    const call = msg([use('abc')])
    const answer = msg([result('abc')])
    const index = buildToolResultIndex([call, answer])

    expect(index.useIds.has('abc')).toBe(true)
    expect(index.byUseId['abc']).toBe(answer.blocks[0])
  })

  it('ignores tool_use blocks without an id', () => {
    const index = buildToolResultIndex([msg([{ type: 'tool_use', name: 'Bash', input: {} }])])
    expect(index.useIds.size).toBe(0)
  })
})

// --- buildCommandPairs ----------------------------------------------------

describe('buildCommandPairs', () => {
  it('absorbs the stdout half that follows a slash command', () => {
    const command = msg([text('<command-name>compact</command-name>')])
    const stdout = msg([text('<local-command-stdout>done</local-command-stdout>')])
    const { stdoutByMessageId, absorbedIds, foldedByCommandId } = buildCommandPairs([command, stdout])

    expect(stdoutByMessageId[command.id]).toBe('done')
    expect(absorbedIds.has(stdout.id)).toBe(true)
    expect(foldedByCommandId[command.id]).toEqual([stdout])
  })

  it('does not pair when the next message opens its own command', () => {
    const a = msg([text('<command-name>one</command-name>')])
    const b = msg([text('<command-name>two</command-name>')])
    const { stdoutByMessageId, absorbedIds } = buildCommandPairs([a, b])

    expect(stdoutByMessageId).toEqual({})
    expect(absorbedIds.size).toBe(0)
  })

  it('does not pair a command with no following stdout', () => {
    const command = msg([text('<command-name>solo</command-name>')])
    const { stdoutByMessageId } = buildCommandPairs([command])
    expect(stdoutByMessageId).toEqual({})
  })
})

// --- hasOwnReason ---------------------------------------------------------

describe('hasOwnReason', () => {
  it('is true when the message anchors an annotation or is published', () => {
    const annotated = msg([])
    expect(hasOwnReason(annotated, new Set([annotated.id]))).toBe(true)
    expect(hasOwnReason(msg([], { published: true }), none)).toBe(true)
  })

  it('is false for a plain message', () => {
    expect(hasOwnReason(msg([result('x')]), none)).toBe(false)
  })
})

// --- isAbsorbed -----------------------------------------------------------

describe('isAbsorbed', () => {
  const index = { byUseId: {}, useIds: new Set(['abc']) }

  it('absorbs a turn that is only resolved tool_results', () => {
    expect(isAbsorbed(msg([result('abc')]), index, none)).toBe(true)
  })

  it('keeps a turn that carries its own reason to stay', () => {
    const annotated = msg([result('abc')])
    expect(isAbsorbed(annotated, index, new Set([annotated.id]))).toBe(false)
    expect(isAbsorbed(msg([result('abc')], { published: true }), index, none)).toBe(false)
  })

  it('keeps a turn whose result is unresolved (no matching tool_use)', () => {
    expect(isAbsorbed(msg([result('missing')]), index, none)).toBe(false)
  })

  it('keeps a turn with any non-result block', () => {
    expect(isAbsorbed(msg([result('abc'), text('hi')]), index, none)).toBe(false)
  })

  it('does not absorb an empty turn', () => {
    expect(isAbsorbed(msg([]), index, none)).toBe(false)
  })
})

// --- buildFoldedIndex -----------------------------------------------------

describe('buildFoldedIndex', () => {
  it('folds an absorbed result turn under the turn that owns its tool_use', () => {
    const call = msg([use('abc')])
    const answer = msg([result('abc')])
    const toolResults = buildToolResultIndex([call, answer])

    const folded = buildFoldedIndex([call, answer], toolResults, {}, none)
    expect(folded[call.id]).toEqual([answer])
  })

  it('preserves command-stdout folds passed in, merging with result folds', () => {
    const command = msg([text('<command-name>x</command-name>')])
    const stdout = msg([text('<local-command-stdout>y</local-command-stdout>')])
    const call = msg([use('abc')])
    const answer = msg([result('abc')])
    const messages = [command, stdout, call, answer]
    const toolResults = buildToolResultIndex(messages)

    const folded = buildFoldedIndex(messages, toolResults, { [command.id]: [stdout] }, none)
    expect(folded[command.id]).toEqual([stdout])
    expect(folded[call.id]).toEqual([answer])
  })
})

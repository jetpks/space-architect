import { describe, expect, it } from 'vitest'
import { initialState, mergedMessages, reduce } from '@/lib/sse-reducer'
import type { SSEEvent, SSEState } from '@/lib/sse-reducer'

function applyAll(events: SSEEvent[]): SSEState {
  return events.reduce((s, ev) => reduce(s, ev), initialState)
}

// Helper: apply events each with an explicit SSE frame id.
function applyWithIds(pairs: [SSEEvent, string][]): SSEState {
  return pairs.reduce((s, [ev, id]) => reduce(s, ev, id), initialState)
}

// --- run_init ---

describe('reduce — run_init', () => {
  it('sets status to live', () => {
    const state = reduce(initialState, { type: 'run_init' })
    expect(state.status).toBe('live')
  })
})

// --- message lifecycle ---

describe('reduce — message_start / message_complete', () => {
  it('creates a message on message_start', () => {
    const state = reduce(initialState, {
      type: 'message_start',
      role: 'assistant',
      model: 'claude-3',
      message_id: 'msg-1',
    })
    expect(state.messages).toHaveLength(1)
    expect(state.messages[0].role).toBe('assistant')
    expect(state.messages[0].model).toBe('claude-3')
    expect(state.messages[0].complete).toBe(false)
  })

  it('marks the message complete on message_complete', () => {
    const state = applyAll([
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      { type: 'message_complete', message_id: 'msg-1', stop_reason: 'end_turn', usage: null },
    ])
    expect(state.messages[0].complete).toBe(true)
  })

  it('accumulates multiple messages', () => {
    const state = applyAll([
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      { type: 'message_complete', message_id: 'msg-1', stop_reason: 'end_turn', usage: null },
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-2' },
    ])
    expect(state.messages).toHaveLength(2)
  })

  it('sets status to live on message_start', () => {
    const state = reduce(initialState, {
      type: 'message_start',
      role: 'assistant',
      model: null,
      message_id: 'msg-1',
    })
    expect(state.status).toBe('live')
  })
})

// --- text block ---

describe('reduce — text block', () => {
  it('accumulates text_deltas and commits on block_close', () => {
    const state = applyAll([
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      { type: 'block_open', block_id: '0', index: 0, block_type: 'text' },
      { type: 'text_delta', block_id: '0', text: 'Hello ' },
      { type: 'text_delta', block_id: '0', text: 'world' },
      { type: 'block_close', block_id: '0' },
    ])
    expect(state.messages[0].blocks).toHaveLength(1)
    expect(state.messages[0].blocks[0]).toEqual({ type: 'text', text: 'Hello world' })
  })

  it('ignores text_delta for unknown block_id', () => {
    const state = applyAll([
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      { type: 'text_delta', block_id: 'unknown', text: 'nope' },
    ])
    expect(state.messages[0].blocks).toHaveLength(0)
  })
})

// --- tool_use block ---

describe('reduce — tool_use block', () => {
  it('assembles a tool_use block from open + args_delta + close', () => {
    const state = applyAll([
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      {
        type: 'block_open',
        block_id: '0',
        index: 0,
        block_type: 'tool_use',
        name: 'Bash',
        tool_use_id: 'tu-1',
      },
      { type: 'tool_args_delta', block_id: '0', partial_json: '{"command":"ls"}' },
      { type: 'block_close', block_id: '0' },
    ])
    const block = state.messages[0].blocks[0]
    expect(block.type).toBe('tool_use')
    expect(block['name']).toBe('Bash')
    expect(block['id']).toBe('tu-1')
    expect(block['input']).toEqual({ command: 'ls' })
  })

  it('concatenates streamed partial_json fragments', () => {
    const state = applyAll([
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      { type: 'block_open', block_id: '0', index: 0, block_type: 'tool_use', name: 'Read', tool_use_id: 'tu-2' },
      { type: 'tool_args_delta', block_id: '0', partial_json: '{"file_path":' },
      { type: 'tool_args_delta', block_id: '0', partial_json: '"readme.md"}' },
      { type: 'block_close', block_id: '0' },
    ])
    expect(state.messages[0].blocks[0]['input']).toEqual({ file_path: 'readme.md' })
  })
})

// --- tool_result ---

describe('reduce — tool_result', () => {
  it('flushes pending tool results as a user message on the next message_start', () => {
    const state = applyAll([
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      { type: 'message_complete', message_id: 'msg-1', stop_reason: 'tool_use', usage: null },
      { type: 'tool_result', tool_use_id: 'tu-1', content: 'ok', is_error: false },
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-2' },
    ])
    expect(state.messages).toHaveLength(3)
    expect(state.messages[1].role).toBe('user')
    expect(state.messages[1].complete).toBe(true)
    expect(state.messages[1].blocks[0]).toMatchObject({ type: 'tool_result', tool_use_id: 'tu-1', content: 'ok' })
  })

  it('flushes pending tool results on run_complete', () => {
    const state = applyAll([
      { type: 'tool_result', tool_use_id: 'tu-1', content: 'done', is_error: false },
      { type: 'run_complete' },
    ])
    expect(state.status).toBe('complete')
    expect(state.messages).toHaveLength(1)
    expect(state.messages[0].role).toBe('user')
  })

  it('marks is_error=true for error results', () => {
    const state = applyAll([
      { type: 'tool_result', tool_use_id: 'tu-err', content: 'failed', is_error: true },
      { type: 'run_complete' },
    ])
    const block = state.messages[0].blocks[0]
    expect(block['is_error']).toBe(true)
  })
})

// --- run_complete ---

describe('reduce — run_complete', () => {
  it('sets status to complete', () => {
    const state = reduce(initialState, { type: 'run_complete' })
    expect(state.status).toBe('complete')
  })
})

// --- mergedMessages ---

describe('mergedMessages', () => {
  it('returns empty array when there are no messages', () => {
    expect(mergedMessages(initialState)).toEqual([])
  })

  it('returns messages as-is when all are complete', () => {
    const state = applyAll([
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      { type: 'message_complete', message_id: 'msg-1', stop_reason: 'end_turn', usage: null },
    ])
    expect(mergedMessages(state)).toEqual(state.messages)
  })

  it('merges open text block into the current message for live rendering', () => {
    const state = applyAll([
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      { type: 'block_open', block_id: '0', index: 0, block_type: 'text' },
      { type: 'text_delta', block_id: '0', text: 'streaming…' },
      // block NOT closed — still open
    ])
    const msgs = mergedMessages(state)
    expect(msgs).toHaveLength(1)
    expect(msgs[0].blocks).toHaveLength(1)
    expect(msgs[0].blocks[0]).toEqual({ type: 'text', text: 'streaming…' })
    // original state unchanged
    expect(state.messages[0].blocks).toHaveLength(0)
  })

  it('includes closed blocks before the open one', () => {
    const state = applyAll([
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      { type: 'block_open', block_id: '0', index: 0, block_type: 'text' },
      { type: 'text_delta', block_id: '0', text: 'done' },
      { type: 'block_close', block_id: '0' },
      { type: 'block_open', block_id: '1', index: 1, block_type: 'text' },
      { type: 'text_delta', block_id: '1', text: 'live' },
    ])
    const msgs = mergedMessages(state)
    expect(msgs[0].blocks).toHaveLength(2)
    expect(msgs[0].blocks[0]).toEqual({ type: 'text', text: 'done' })
    expect(msgs[0].blocks[1]).toEqual({ type: 'text', text: 'live' })
  })
})

// --- full sequence sample ---

describe('full event sequence', () => {
  it('produces the expected message state for a complete assistant + tool round', () => {
    const state = applyAll([
      { type: 'run_init', session_id: 's1', model: 'claude-3', cwd: '/tmp', tools: [] },
      { type: 'message_start', role: 'assistant', model: 'claude-3', message_id: 'msg-1' },
      { type: 'block_open', block_id: '0', index: 0, block_type: 'text' },
      { type: 'text_delta', block_id: '0', text: 'Let me check.' },
      { type: 'block_close', block_id: '0' },
      { type: 'block_open', block_id: '1', index: 1, block_type: 'tool_use', name: 'Bash', tool_use_id: 'tu-1' },
      { type: 'tool_args_delta', block_id: '1', partial_json: '{"command":"pwd"}' },
      { type: 'block_close', block_id: '1' },
      { type: 'message_complete', message_id: 'msg-1', stop_reason: 'tool_use', usage: null },
      { type: 'tool_result', tool_use_id: 'tu-1', content: '/home/user', is_error: false },
      { type: 'message_start', role: 'assistant', model: 'claude-3', message_id: 'msg-2' },
      { type: 'block_open', block_id: '0', index: 0, block_type: 'text' },
      { type: 'text_delta', block_id: '0', text: 'Done.' },
      { type: 'block_close', block_id: '0' },
      { type: 'message_complete', message_id: 'msg-2', stop_reason: 'end_turn', usage: null },
      { type: 'run_complete' },
    ])

    expect(state.status).toBe('complete')
    expect(state.messages).toHaveLength(3)

    // msg-1: assistant with text + tool_use
    expect(state.messages[0].role).toBe('assistant')
    expect(state.messages[0].blocks).toHaveLength(2)
    expect(state.messages[0].blocks[0]).toEqual({ type: 'text', text: 'Let me check.' })
    expect(state.messages[0].blocks[1].type).toBe('tool_use')
    expect(state.messages[0].blocks[1]['name']).toBe('Bash')

    // flushed user message with tool_result
    expect(state.messages[1].role).toBe('user')
    expect(state.messages[1].blocks[0]).toMatchObject({ type: 'tool_result', content: '/home/user' })

    // msg-2: assistant conclusion
    expect(state.messages[2].role).toBe('assistant')
    expect(state.messages[2].blocks[0]).toEqual({ type: 'text', text: 'Done.' })
  })
})

// --- reconnect / gap detection ---

describe('reconnect — no duplicate on replay', () => {
  it('skips an event whose SSE id was already applied (dedup)', () => {
    // Apply a message_start with id "100-0", then "replay" the same id on reconnect.
    const after1 = reduce(
      initialState,
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      '100-0',
    )
    expect(after1.messages).toHaveLength(1)
    expect(after1.lastAppliedId).toBe('100-0')

    // Simulate reconnect: server mistakenly replays the same event with the same id.
    const after2 = reduce(
      after1,
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      '100-0',
    )
    // Must not add a second message — dedup skipped it.
    expect(after2.messages).toHaveLength(1)
    expect(after2.gapDetected).toBe(true)
  })

  it('applies new events normally after a reconnect with advancing ids', () => {
    const s1 = reduce(
      initialState,
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      '100-0',
    )
    // Reconnect resumes from "(100-0" — server sends next event with strictly higher id.
    const s2 = reduce(
      s1,
      { type: 'block_open', block_id: '0', index: 0, block_type: 'text' },
      '200-0',
    )
    const s3 = reduce(s2, { type: 'text_delta', block_id: '0', text: 'resumed' }, '300-0')
    expect(s3.gapDetected).toBe(false)
    expect(s3.lastAppliedId).toBe('300-0')
    // Open block contains the delta — no duplication.
    expect(Object.values(s3.openBlocks)[0]?.text).toBe('resumed')
  })
})

describe('run_complete — stops further event processing', () => {
  it('ignores events received after run_complete', () => {
    const after = applyAll([
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' },
      { type: 'run_complete' },
      // These arrive after complete (e.g. reconnect that shouldn't happen).
      { type: 'message_start', role: 'assistant', model: null, message_id: 'msg-2' },
      { type: 'text_delta', block_id: '0', text: 'ghost' },
    ])
    expect(after.status).toBe('complete')
    // Only the message from before run_complete is present.
    expect(after.messages).toHaveLength(1)
  })
})

describe('numeric id comparison — multi-digit seq', () => {
  it('applies a forward event when seq crosses a digit boundary (0-9 -> 0-10)', () => {
    const state = applyWithIds([
      [{ type: 'run_init' }, '0-9'],
      [{ type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' }, '0-10'],
    ])
    expect(state.lastAppliedId).toBe('0-10')
    expect(state.gapDetected).toBe(false)
    expect(state.messages).toHaveLength(1)
  })

  it('skips a duplicate/backward id and sets gapDetected (0-9 received after 0-10)', () => {
    const state = applyWithIds([
      [{ type: 'run_init' }, '0-9'],
      [{ type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' }, '0-10'],
      [{ type: 'message_start', role: 'assistant', model: null, message_id: 'msg-dup' }, '0-9'],
    ])
    expect(state.gapDetected).toBe(true)
    expect(state.messages).toHaveLength(1)
    expect(state.lastAppliedId).toBe('0-10')
  })

  it('applies a forward event when same-ms seq crosses digit boundary (…-9 -> …-10)', () => {
    const state = applyWithIds([
      [{ type: 'run_init' }, '1718000000000-9'],
      [{ type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' }, '1718000000000-10'],
    ])
    expect(state.lastAppliedId).toBe('1718000000000-10')
    expect(state.gapDetected).toBe(false)
    expect(state.messages).toHaveLength(1)
  })
})

describe('gap detection', () => {
  it('flags gapDetected when a stale id is received (id skipped backward)', () => {
    // Apply events up to "500-0", then receive an older event "200-0" — indicates
    // the server resumed from the wrong position and an id was skipped.
    const s1 = applyWithIds([
      [{ type: 'message_start', role: 'assistant', model: null, message_id: 'msg-1' }, '100-0'],
      [{ type: 'block_open', block_id: '0', index: 0, block_type: 'text' }, '200-0'],
      [{ type: 'text_delta', block_id: '0', text: 'hello' }, '300-0'],
      [{ type: 'block_close', block_id: '0' }, '400-0'],
      [{ type: 'message_complete', message_id: 'msg-1', stop_reason: 'end_turn', usage: null }, '500-0'],
    ])
    expect(s1.gapDetected).toBe(false)
    expect(s1.lastAppliedId).toBe('500-0')

    // Receive stale event with id "200-0" (already applied).
    const s2 = reduce(s1, { type: 'run_init' }, '200-0')
    expect(s2.gapDetected).toBe(true)
    // State is otherwise unchanged.
    expect(s2.messages).toHaveLength(1)
  })
})

import type { Block, ToolResultBlock } from '@/types'

// An SSE event payload parsed from the `data:` field of a server-sent event.
// The `type` field determines how it is handled; all other fields are event-specific.
export type SSEEvent = { type: string; [key: string]: unknown }

// A single message accumulated from SSE events.
export type LiveMessage = {
  message_id: string | null
  role: string
  model: string | null
  blocks: Block[]
  complete: boolean
}

// A content block currently being streamed (not yet closed).
type OpenBlock = {
  block_id: string
  block_type: string
  name: string | null
  tool_use_id: string | null
  text: string
  partial_json: string
}

export type SSEState = {
  messages: LiveMessage[]
  // Blocks being assembled between block_open and block_close.
  openBlocks: Record<string, OpenBlock>
  // tool_result events between assistant messages; flushed as a user message
  // on the next message_start or run_complete.
  pendingUserBlocks: ToolResultBlock[]
  status: 'pending' | 'live' | 'complete'
  // Last SSE `id:` frame field applied — used for reconnect dedup and gap detection.
  lastAppliedId: string | null
  // True when a stale or out-of-order SSE id was received (id <= lastAppliedId).
  gapDetected: boolean
}

export const initialState: SSEState = {
  messages: [],
  openBlocks: {},
  pendingUserBlocks: [],
  status: 'pending',
  lastAppliedId: null,
  gapDetected: false,
}

// sseId: the SSE frame `id:` field from MessageEvent.lastEventId, if present.
export function reduce(state: SSEState, event: SSEEvent, sseId?: string): SSEState {
  // Once complete, ignore further events — the stream is closed and won't reconnect.
  if (state.status === 'complete') return state

  // Dedup: skip events already applied; flag stale delivery so callers can react.
  if (sseId && state.lastAppliedId !== null && compareId(sseId, state.lastAppliedId) <= 0) {
    return { ...state, gapDetected: true }
  }

  const next = applyEvent(state, event)
  return sseId ? { ...next, lastAppliedId: sseId } : next
}

function applyEvent(state: SSEState, event: SSEEvent): SSEState {
  switch (event.type) {
    case 'run_init':
      return { ...state, status: 'live' }

    case 'message_start': {
      const flushed = flushPending(state)
      const msg: LiveMessage = {
        message_id: typeof event.message_id === 'string' ? event.message_id : null,
        role: typeof event.role === 'string' ? event.role : 'assistant',
        model: typeof event.model === 'string' ? event.model : null,
        blocks: [],
        complete: false,
      }
      return { ...flushed, messages: [...flushed.messages, msg], openBlocks: {}, status: 'live' }
    }

    case 'block_open': {
      const block: OpenBlock = {
        block_id: typeof event.block_id === 'string' ? event.block_id : '',
        block_type: typeof event.block_type === 'string' ? event.block_type : 'text',
        name: typeof event.name === 'string' ? event.name : null,
        tool_use_id: typeof event.tool_use_id === 'string' ? event.tool_use_id : null,
        text: '',
        partial_json: '',
      }
      return { ...state, openBlocks: { ...state.openBlocks, [block.block_id]: block } }
    }

    case 'text_delta': {
      const blockId = typeof event.block_id === 'string' ? event.block_id : ''
      const ob = state.openBlocks[blockId]
      if (!ob) return state
      const appended = typeof event.text === 'string' ? event.text : ''
      return {
        ...state,
        openBlocks: { ...state.openBlocks, [blockId]: { ...ob, text: ob.text + appended } },
      }
    }

    case 'tool_args_delta': {
      const blockId = typeof event.block_id === 'string' ? event.block_id : ''
      const ob = state.openBlocks[blockId]
      if (!ob) return state
      const appended = typeof event.partial_json === 'string' ? event.partial_json : ''
      return {
        ...state,
        openBlocks: {
          ...state.openBlocks,
          [blockId]: { ...ob, partial_json: ob.partial_json + appended },
        },
      }
    }

    case 'block_close': {
      const blockId = typeof event.block_id === 'string' ? event.block_id : ''
      const ob = state.openBlocks[blockId]
      if (!ob) return state

      const block = toBlock(ob)
      const msgs = state.messages.length ? pushBlock(state.messages, block) : state.messages
      const openBlocks = Object.fromEntries(
        Object.entries(state.openBlocks).filter(([id]) => id !== blockId),
      )
      return { ...state, messages: msgs, openBlocks }
    }

    case 'message_complete': {
      if (state.messages.length === 0) return state
      const msgs = [...state.messages]
      msgs[msgs.length - 1] = { ...msgs[msgs.length - 1], complete: true }
      return { ...state, messages: msgs }
    }

    case 'tool_result': {
      const block: ToolResultBlock = {
        type: 'tool_result',
        tool_use_id: typeof event.tool_use_id === 'string' ? event.tool_use_id : undefined,
        content: typeof event.content === 'string' ? event.content : '',
        is_error: event.is_error === true,
      }
      return { ...state, pendingUserBlocks: [...state.pendingUserBlocks, block] }
    }

    case 'run_complete':
      return { ...flushPending(state), status: 'complete' }

    default:
      return state
  }
}

// Merge open (not yet closed) blocks into the current incomplete message so the
// page can render streaming text without waiting for block_close.
export function mergedMessages(state: SSEState): LiveMessage[] {
  if (state.messages.length === 0) return []
  const last = state.messages[state.messages.length - 1]
  if (last.complete) return state.messages

  const streaming = Object.values(state.openBlocks).map(toBlock)
  if (streaming.length === 0) return state.messages

  const live: LiveMessage = { ...last, blocks: [...last.blocks, ...streaming] }
  return [...state.messages.slice(0, -1), live]
}

function flushPending(state: SSEState): SSEState {
  if (state.pendingUserBlocks.length === 0) return state
  const userMsg: LiveMessage = {
    message_id: null,
    role: 'user',
    model: null,
    blocks: state.pendingUserBlocks,
    complete: true,
  }
  return { ...state, messages: [...state.messages, userMsg], pendingUserBlocks: [] }
}

function pushBlock(messages: LiveMessage[], block: Block): LiveMessage[] {
  const msgs = [...messages]
  const last = msgs[msgs.length - 1]
  msgs[msgs.length - 1] = { ...last, blocks: [...last.blocks, block] }
  return msgs
}

// Compare Redis stream ids "<ms>-<seq>" numerically (ms first, then seq).
function compareId(a: string, b: string): number {
  const [ams, aseq] = a.split('-').map(Number)
  const [bms, bseq] = b.split('-').map(Number)
  return ams !== bms ? ams - bms : aseq - bseq
}

function tryParseJson(s: string): unknown {
  try {
    return JSON.parse(s || '{}')
  } catch {
    return {}
  }
}

function toBlock(ob: OpenBlock): Block {
  switch (ob.block_type) {
    case 'text':
      return { type: 'text', text: ob.text }
    case 'thinking':
      return { type: 'thinking', thinking: ob.text }
    case 'tool_use':
      return {
        type: 'tool_use',
        id: ob.tool_use_id ?? undefined,
        name: ob.name ?? '',
        input: tryParseJson(ob.partial_json),
      }
    default:
      return { type: ob.block_type, text: ob.text }
  }
}

import { act } from 'react'
import { render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { Run } from '@/types'

vi.mock('@inertiajs/react', () => ({
  Head: (_props: { title?: string }) => null,
  usePage: () => ({ props: { current_user: null, flash: {} } }),
  useForm: () => ({
    data: {} as Record<string, string>,
    setData: () => {},
    post: () => {},
    processing: false,
    errors: {} as Record<string, string>,
  }),
  router: { patch: () => {}, delete: () => {}, post: () => {} },
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

import Show from './Show'

// A minimal stand-in for the browser EventSource — gives tests direct control
// over onmessage/onerror delivery and observability into close()/construction,
// which the house mocking idiom (vi.mock the module boundary) can't reach here
// since EventSource is a global, not an import.
class MockEventSource {
  static instances: MockEventSource[] = []
  url: string
  closed = false
  onmessage: ((e: MessageEvent) => void) | null = null
  onerror: (() => void) | null = null

  constructor(url: string) {
    this.url = url
    MockEventSource.instances.push(this)
  }

  close() {
    this.closed = true
  }

  // Wrapped in act(): this drives a setState synchronously outside any DOM
  // event, so React won't flush it before the next assertion otherwise.
  emit(data: unknown, lastEventId = '') {
    act(() => {
      this.onmessage?.({ data: JSON.stringify(data), lastEventId } as MessageEvent)
    })
  }
}

function setVisibility(state: DocumentVisibilityState) {
  act(() => {
    Object.defineProperty(document, 'visibilityState', { value: state, configurable: true })
    document.dispatchEvent(new Event('visibilitychange'))
  })
}

const RUN: Run = { id: 1, status: 'live', published: false }

describe('Runs/Show', () => {
  beforeEach(() => {
    MockEventSource.instances = []
    vi.stubGlobal('EventSource', MockEventSource)
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true })
  })

  it('opens a live EventSource on mount and renders streamed content', () => {
    render(<Show run={RUN} />)

    expect(MockEventSource.instances).toHaveLength(1)
    expect(MockEventSource.instances[0].url).toBe('/runs/1/stream')

    const es = MockEventSource.instances[0]
    es.emit({ type: 'message_start', role: 'assistant', model: 'claude' }, '1-1')
    es.emit({ type: 'block_open', block_id: '0', index: 0, block_type: 'text' }, '1-2')
    es.emit({ type: 'text_delta', block_id: '0', text: 'hello live' }, '1-3')

    expect(screen.queryByText('hello live')).not.toBeNull()
  })

  it('re-syncs on refocus while the run is live: closes the stale connection and opens a fresh one', () => {
    render(<Show run={RUN} />)
    const first = MockEventSource.instances[0]
    first.emit({ type: 'message_start', role: 'assistant', model: 'claude' }, '1-1')

    setVisibility('hidden')
    setVisibility('visible')

    expect(first.closed).toBe(true)
    expect(MockEventSource.instances).toHaveLength(2)
    expect(MockEventSource.instances[1].closed).toBe(false)
    expect(MockEventSource.instances[1].url).toBe('/runs/1/stream')
  })

  it('does not open a new connection on refocus once the run is complete', () => {
    render(<Show run={RUN} />)
    const first = MockEventSource.instances[0]
    first.emit({ type: 'run_complete' }, '1-9')

    setVisibility('hidden')
    setVisibility('visible')

    expect(MockEventSource.instances).toHaveLength(1)
  })
})

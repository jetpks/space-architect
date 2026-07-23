import { act } from 'react'
import { render, screen } from '@testing-library/react'
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'

vi.mock('@inertiajs/react', () => ({
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

// A minimal stand-in for the browser EventSource — see Runs/Show.test.tsx,
// which exercised this same connect/reconnect logic before it moved here.
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

  emit(data: unknown, lastEventId = '') {
    act(() => {
      this.onmessage?.({ data: JSON.stringify(data), lastEventId } as MessageEvent)
    })
  }
}

import RunStream from './RunStream'

describe('RunStream', () => {
  beforeEach(() => {
    MockEventSource.instances = []
    vi.stubGlobal('EventSource', MockEventSource)
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('opens a live EventSource for the given run on mount', () => {
    render(<RunStream runId={1} />)
    expect(MockEventSource.instances).toHaveLength(1)
    expect(MockEventSource.instances[0].url).toBe('/runs/1/stream')
  })

  it('renders streamed content', () => {
    render(<RunStream runId={1} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'message_start', role: 'assistant', model: 'claude' }, '1-1')
    es.emit({ type: 'block_open', block_id: '0', index: 0, block_type: 'text' }, '1-2')
    es.emit({ type: 'text_delta', block_id: '0', text: 'hello live' }, '1-3')
    expect(screen.queryByText('hello live')).not.toBeNull()
  })

  it('renders the prompt as a leading turn when provided', () => {
    const { container } = render(<RunStream runId={1} prompt="Write six aphorisms" />)
    const list = container.querySelector('ol')!
    expect(list.children[0].textContent).toContain('Write six aphorisms')
  })

  it('renders no leading turn when prompt is absent', () => {
    const { container } = render(<RunStream runId={1} />)
    const list = container.querySelector('ol')!
    expect(list.children).toHaveLength(0)
  })

  it('reports status transitions via onStatusChange', () => {
    const onStatusChange = vi.fn()
    render(<RunStream runId={1} onStatusChange={onStatusChange} />)
    expect(onStatusChange).toHaveBeenCalledWith('pending')

    const es = MockEventSource.instances[0]
    es.emit({ type: 'message_start', role: 'assistant', model: 'claude' }, '1-1')
    expect(onStatusChange).toHaveBeenCalledWith('live')
  })
})

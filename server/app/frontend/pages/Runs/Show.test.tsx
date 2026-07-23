import { act } from 'react'
import { render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { Run } from '@/types'

vi.mock('@inertiajs/react', () => ({
  Head: (_props: { title?: string }) => null,
  Link: ({ href, children }: { href: string; children?: ReactNode }) => <a href={href}>{children}</a>,
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

const RUN: Run = {
  id: 1,
  status: 'live',
  published: false,
  role: 'builder',
  harness: 'claude',
  model: 'qwen3-27b-optiq',
  producer: null,
  created_at: '2026-07-19T14:14:59Z',
  updated_at: '2026-07-19T14:16:32Z',
  job: null,
}

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

  it('renders run metadata and the owner-only job prompt', () => {
    const run: Run = {
      ...RUN,
      job: { id: 19, status: 'succeeded', prompt: 'Write six aphorisms' },
    }
    render(<Show run={run} />)

    expect(screen.queryByText('claude')).not.toBeNull()
    expect(screen.queryByText('qwen3-27b-optiq')).not.toBeNull()
    expect(screen.queryByText('builder')).not.toBeNull()
    expect(screen.queryByText('#19')).not.toBeNull()
    expect(screen.queryByText('Write six aphorisms')).not.toBeNull()
  })

  it('omits the job row and prompt when job is null (non-owner or ingested run)', () => {
    render(<Show run={RUN} />)

    expect(screen.queryByText('Prompt')).toBeNull()
    expect(screen.queryByText('Job')).toBeNull()
  })

  it('renders the prompt as a leading user-styled turn, exactly once', () => {
    const run: Run = {
      ...RUN,
      job: { id: 19, status: 'succeeded', prompt: 'Write six aphorisms' },
    }
    const { container } = render(<Show run={run} />)

    const matches = screen.getAllByText('Write six aphorisms')
    expect(matches).toHaveLength(1)

    const list = container.querySelector('ol')!
    const firstItem = list.children[0]
    expect(firstItem.textContent).toContain('Write six aphorisms')
    expect(firstItem.textContent).toContain('user')
  })

  it('does not render a leading turn when the job has no prompt', () => {
    const run: Run = { ...RUN, job: null }
    const { container } = render(<Show run={run} />)
    const list = container.querySelector('ol')!
    expect(list.children).toHaveLength(0)
  })

  it('renders a distinct badge for a canceled run, not the failed styling', () => {
    const run: Run = { ...RUN, status: 'canceled' }
    render(<Show run={run} />)
    const badge = screen.getByText('canceled')
    expect(badge.getAttribute('data-variant')).toBe('outline')
    expect(badge.getAttribute('data-variant')).not.toBe('destructive')
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

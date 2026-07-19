import { render } from '@testing-library/react'
import { describe, expect, it, vi, afterEach } from 'vitest'
import type { ReactNode } from 'react'
import type { JobDetail } from '@/types'

const { reload } = vi.hoisted(() => ({ reload: vi.fn() }))

vi.mock('@inertiajs/react', () => ({
  Link: ({ href, children }: { href: string; children?: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
  Head: (_props: { title?: string }) => null,
  router: { reload },
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

import Show from './Show'

const JOB: JobDetail = {
  id: 1,
  status: 'succeeded',
  attempts: 1,
  run_id: 7,
  spec: {
    harness: { type: 'claude', model: 'claude-sonnet-5', backend: { base_url: 'https://api.example.com' } },
    prompt: 'do the thing',
    environment: {},
  },
  created_at: '2026-06-28T21:32:12.278Z',
  updated_at: '2026-06-28T21:33:00.000Z',
}

describe('Jobs/Show', () => {
  afterEach(() => {
    reload.mockClear()
    vi.useRealTimers()
  })

  it('renders the status badge', () => {
    const { container } = render(<Show job={JOB} />)
    expect(container.textContent).toContain('succeeded')
  })

  it('renders a link to the live run page when run_id is set', () => {
    const { container } = render(<Show job={JOB} />)
    expect(container.querySelector('a[href="/runs/7"]')).not.toBeNull()
  })

  it('omits the run link when run_id is null', () => {
    const { container } = render(<Show job={{ ...JOB, run_id: null }} />)
    expect(container.querySelector('a[href^="/runs/"]')).toBeNull()
  })

  it('renders the spec as pretty-printed JSON', () => {
    const { container } = render(<Show job={JOB} />)
    expect(container.textContent).toContain('"prompt": "do the thing"')
  })

  it('polls via router.reload while queued', () => {
    vi.useFakeTimers()
    render(<Show job={{ ...JOB, status: 'queued', run_id: null }} />)
    expect(reload).not.toHaveBeenCalled()
    vi.advanceTimersByTime(2500)
    expect(reload).toHaveBeenCalledWith({ only: ['job'] })
  })

  it('does not poll once the job is in a terminal state', () => {
    vi.useFakeTimers()
    render(<Show job={JOB} />)
    vi.advanceTimersByTime(10000)
    expect(reload).not.toHaveBeenCalled()
  })
})

import { render, fireEvent } from '@testing-library/react'
import { describe, expect, it, vi, afterEach } from 'vitest'
import type { ReactNode } from 'react'
import type { JobDetail } from '@/types'

const { reload, post } = vi.hoisted(() => ({ reload: vi.fn(), post: vi.fn() }))

vi.mock('@inertiajs/react', () => ({
  Link: ({ href, children }: { href: string; children?: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
  Head: (_props: { title?: string }) => null,
  router: { reload, post },
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

vi.mock('@/components/RunStream', () => ({
  default: ({ runId }: { runId: number }) => <div data-testid="run-stream">stream:{runId}</div>,
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
    post.mockClear()
    vi.restoreAllMocks()
    vi.useRealTimers()
  })

  it('renders the status badge', () => {
    const { container } = render(<Show job={JOB} />)
    expect(container.textContent).toContain('succeeded')
  })

  it('renders a distinct badge for a canceled job', () => {
    const { getByText } = render(<Show job={{ ...JOB, status: 'canceled' }} />)
    const badge = getByText('canceled')
    expect(badge.getAttribute('data-variant')).toBe('outline')
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

  it('renders the loop identity line when provenance is present', () => {
    const job = { ...JOB, spec: { ...JOB.spec, provenance: { space: 's1', iteration: 'I16', lane: 'server' } } }
    const { container } = render(<Show job={job} />)
    expect(container.textContent).toContain('s1 · I16 · server')
  })

  it('renders no loop identity line when provenance is absent', () => {
    const { container } = render(<Show job={JOB} />)
    expect(container.querySelector('header p')).toBeNull()
  })

  it.each(['queued', 'running'])('renders a Cancel button while the job is %s', (status) => {
    const { getByRole } = render(<Show job={{ ...JOB, status }} />)
    expect(getByRole('button', { name: 'Cancel' })).not.toBeNull()
  })

  it.each(['succeeded', 'failed', 'canceled'])('omits the Cancel button once the job is %s', (status) => {
    const { queryByRole } = render(<Show job={{ ...JOB, status }} />)
    expect(queryByRole('button', { name: 'Cancel' })).toBeNull()
  })

  it('posts to the cancel endpoint when Cancel is clicked and confirmed', () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    const { getByRole } = render(<Show job={{ ...JOB, status: 'running' }} />)
    fireEvent.click(getByRole('button', { name: 'Cancel' }))
    expect(post).toHaveBeenCalledWith('/jobs/1/cancel')
  })

  it('does not post when the confirm dialog is dismissed', () => {
    vi.spyOn(window, 'confirm').mockReturnValue(false)
    const { getByRole } = render(<Show job={{ ...JOB, status: 'running' }} />)
    fireEvent.click(getByRole('button', { name: 'Cancel' }))
    expect(post).not.toHaveBeenCalled()
  })

  it('renders a "Run again" link to /jobs/new?from=<id>', () => {
    const { container } = render(<Show job={JOB} />)
    expect(container.querySelector('a[href="/jobs/new?from=1"]')).not.toBeNull()
  })

  it('embeds the live run stream when run_id is set', () => {
    const { container } = render(<Show job={JOB} />)
    expect(container.querySelector('[data-testid="run-stream"]')).not.toBeNull()
  })

  it('omits the live run stream when run_id is null', () => {
    const { container } = render(<Show job={{ ...JOB, run_id: null }} />)
    expect(container.querySelector('[data-testid="run-stream"]')).toBeNull()
  })
})

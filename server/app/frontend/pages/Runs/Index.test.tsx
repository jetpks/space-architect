import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { RunListItem } from '@/types'

vi.mock('@inertiajs/react', () => ({
  Link: ({ href, children }: { href: string; children?: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
  Head: (_props: { title?: string }) => null,
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

import Index from './Index'

const RUN: RunListItem = {
  id: 1,
  status: 'complete',
  published: false,
  harness: 'claude',
  model: 'sonnet',
  lane: 'builder-a',
  created_at: '2026-06-28T21:32:12.278Z',
  prompt_snippet: 'do the thing',
}

const NO_PAGINATION = { page: 1, has_more: false }

describe('Runs/Index', () => {
  it('renders a link to each run', () => {
    const { container } = render(<Index runs={[RUN]} pagination={NO_PAGINATION} />)
    expect(container.querySelector('a[href="/runs/1"]')).not.toBeNull()
  })

  it('renders empty state when no runs', () => {
    const { container } = render(<Index runs={[]} pagination={NO_PAGINATION} />)
    expect(container.textContent).toContain('No runs yet')
  })

  it('renders absolute timestamp for created_at with Z fallback (null offset)', () => {
    const { container } = render(<Index runs={[RUN]} pagination={NO_PAGINATION} />)
    expect(container.textContent).toContain('2026-06-28T21:32:12.278Z')
  })

  it('renders the absolute pattern matching ISO8601 with a Z suffix', () => {
    const { container } = render(<Index runs={[RUN]} pagination={NO_PAGINATION} />)
    expect(container.textContent).toMatch(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z/)
  })

  it('renders harness, model, and lane on the row', () => {
    const { container } = render(<Index runs={[RUN]} pagination={NO_PAGINATION} />)
    expect(container.textContent).toContain('claude')
    expect(container.textContent).toContain('sonnet')
    expect(container.textContent).toContain('builder-a')
  })

  it('renders the prompt snippet when present', () => {
    const { container } = render(<Index runs={[RUN]} pagination={NO_PAGINATION} />)
    expect(container.textContent).toContain('do the thing')
  })

  it('omits the prompt snippet when absent (non-owner or no job)', () => {
    const run = { ...RUN, prompt_snippet: null }
    const { container } = render(<Index runs={[run]} pagination={NO_PAGINATION} />)
    expect(container.textContent).not.toContain('do the thing')
  })

  it('renders a distinct badge for a canceled run, not the failed styling', () => {
    const run = { ...RUN, status: 'canceled' as const }
    const { getByText } = render(<Index runs={[run]} pagination={NO_PAGINATION} />)
    const badge = getByText('canceled')
    expect(badge.getAttribute('data-variant')).toBe('outline')
    expect(badge.getAttribute('data-variant')).not.toBe('destructive')
  })

  it('distinguishes two rows by their identity fields', () => {
    const other: RunListItem = {
      id: 2,
      status: 'live',
      published: false,
      harness: 'opencode',
      model: 'gpt-5',
      lane: 'builder-b',
      created_at: '2026-06-28T22:00:00Z',
      prompt_snippet: null,
    }
    const { container } = render(<Index runs={[RUN, other]} pagination={NO_PAGINATION} />)
    expect(container.textContent).toContain('opencode')
    expect(container.textContent).toContain('gpt-5')
    expect(container.textContent).toContain('builder-b')
  })

  it('renders no pagination controls on a lone page', () => {
    const { queryByRole } = render(<Index runs={[RUN]} pagination={NO_PAGINATION} />)
    expect(queryByRole('button', { name: 'Next' })).toBeNull()
  })

  it('renders pagination controls from the prop when a further page exists', () => {
    const { getByRole } = render(<Index runs={[RUN]} pagination={{ page: 2, has_more: true }} />)
    expect(getByRole('button', { name: 'Prev' })).not.toBeDisabled()
    expect(getByRole('button', { name: 'Next' })).not.toBeDisabled()
  })
})

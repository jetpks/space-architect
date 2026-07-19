import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { JobListItem } from '@/types'

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

const JOB: JobListItem = {
  id: 1,
  status: 'running',
  model: 'claude-sonnet-5',
  created_at: '2026-06-28T21:32:12.278Z',
  run_id: 7,
}

describe('Jobs/Index', () => {
  it('renders a link to each job', () => {
    const { container } = render(<Index jobs={[JOB]} />)
    expect(container.querySelector('a[href="/jobs/1"]')).not.toBeNull()
  })

  it('renders a status badge for every one of the five job states', () => {
    const states = ['queued', 'running', 'succeeded', 'failed', 'canceled']
    const jobs = states.map((status, i) => ({ ...JOB, id: i + 1, status }))
    const { container } = render(<Index jobs={jobs} />)
    for (const status of states) {
      expect(container.textContent).toContain(status)
    }
  })

  it('renders a "New job" link to /jobs/new', () => {
    const { container } = render(<Index jobs={[]} />)
    expect(container.querySelector('a[href="/jobs/new"]')).not.toBeNull()
  })

  it('renders empty state when no jobs', () => {
    const { container } = render(<Index jobs={[]} />)
    expect(container.textContent).toContain('No jobs yet')
  })
})

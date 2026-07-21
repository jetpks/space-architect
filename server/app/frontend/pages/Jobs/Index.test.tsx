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
  harness: 'claude',
  prompt_snippet: 'do the thing',
  created_at: '2026-06-28T21:32:12.278Z',
  run_id: 7,
}

describe('Jobs/Index', () => {
  it('renders a link to each job', () => {
    const { container } = render(<Index jobs={[JOB]} />)
    expect(container.querySelector('a[href="/jobs/1"]')).not.toBeNull()
  })

  it('renders harness type and prompt snippet', () => {
    const { container } = render(<Index jobs={[JOB]} />)
    expect(container.textContent).toContain('claude')
    expect(container.textContent).toContain('do the thing')
  })

  it('renders provenance when present', () => {
    const job = { ...JOB, provenance: { space: 's1', iteration: 'I16', lane: 'server' } }
    const { container } = render(<Index jobs={[job]} />)
    expect(container.textContent).toContain('s1')
    expect(container.textContent).toContain('I16')
    expect(container.textContent).toContain('server')
  })

  it('links run_id to its run page', () => {
    const { container } = render(<Index jobs={[JOB]} />)
    expect(container.querySelector('a[href="/runs/7"]')).not.toBeNull()
  })

  it('omits the run link when run_id is null', () => {
    const job = { ...JOB, run_id: null }
    const { container } = render(<Index jobs={[job]} />)
    expect(container.querySelector('a[href="/runs/7"]')).toBeNull()
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

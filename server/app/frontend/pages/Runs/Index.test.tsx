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
  created_at: '2026-06-28T21:32:12.278Z',
}

describe('Runs/Index', () => {
  it('renders a link to each run', () => {
    const { container } = render(<Index runs={[RUN]} />)
    expect(container.querySelector('a[href="/runs/1"]')).not.toBeNull()
  })

  it('renders empty state when no runs', () => {
    const { container } = render(<Index runs={[]} />)
    expect(container.textContent).toContain('No runs yet')
  })

  it('renders absolute timestamp for created_at with UTC fallback (null offset)', () => {
    const { container } = render(<Index runs={[RUN]} />)
    // null offset → UTC +0000
    expect(container.textContent).toContain('2026-06-28T21:32:12.278+0000')
  })

  it('renders the absolute pattern matching ISO8601 with colon-less offset', () => {
    const { container } = render(<Index runs={[RUN]} />)
    expect(container.textContent).toMatch(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d{4}/)
  })
})

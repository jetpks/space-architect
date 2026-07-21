import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { SpaceListItem } from '@/types'

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

const SPACE: SpaceListItem = {
  id: 1,
  slug: 'test-space',
  title: 'Test Space',
  status: 'active',
  iterations_count: 2,
  runs_count: 3,
  imported_at: '2026-06-28T21:32:12.278Z',
  git_utc_offset: -21600,
}

describe('Spaces/Index', () => {
  it('renders a link to each space', () => {
    const { container } = render(<Index spaces={[SPACE]} />)
    expect(container.querySelector('a[href="/spaces/1"]')).not.toBeNull()
  })

  it('renders empty state when no spaces', () => {
    const { container } = render(<Index spaces={[]} />)
    expect(container.textContent).toContain('No spaces yet')
  })

  it('renders the absolute timestamp for imported_at in space git_utc_offset', () => {
    const { container } = render(<Index spaces={[SPACE]} />)
    // 2026-06-28T21:32:12.278Z with -21600s offset → 2026-06-28T15:32:12.278-06:00
    expect(container.textContent).toContain('2026-06-28T15:32:12.278-06:00')
  })

  it('renders UTC fallback when git_utc_offset is null', () => {
    const space: SpaceListItem = { ...SPACE, git_utc_offset: null }
    const { container } = render(<Index spaces={[space]} />)
    expect(container.textContent).toMatch(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z/)
  })
})

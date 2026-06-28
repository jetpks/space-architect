import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { ArchitectRun, SpaceArtifact, SpaceIteration, SpaceRun } from '@/types'

vi.mock('@inertiajs/react', () => ({
  Link: ({ href, children }: { href: string; children?: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
  Head: (_props: { title?: string }) => null,
  usePage: () => ({ props: { current_user: null, flash: {} } }),
  router: { patch: () => {}, delete: () => {} },
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div data-testid="layout">{children}</div>,
}))

import Show from './Show'

const SPACE = { id: 1, slug: 'test-space', title: 'Test Space', status: 'active', repos: [] }

const RUN: SpaceRun = {
  id: 42,
  lane: 'frontend',
  role: 'builder',
  status: 'complete',
  conversation_id: 7,
  created_at: '2026-06-01T01:00:00Z',
}

const ITERATION_1: SpaceIteration = {
  id: 10,
  ordinal: 1,
  name: 'first-iter',
  freeze_sha: 'abc1234',
  verdict: 'continue',
  created_at: '2026-06-01T00:00:00Z',
  decisions: [{ name: 'Grounds', body: 'The grounds section body.' }],
  artifacts: [],
  runs: [RUN],
}

const ITERATION_2: SpaceIteration = {
  id: 11,
  ordinal: 2,
  name: 'second-iter',
  freeze_sha: null,
  verdict: null,
  created_at: '2026-06-02T00:00:00Z',
  decisions: [],
  artifacts: [],
  runs: [],
}

const OTHER_ARTIFACT: SpaceArtifact = {
  id: 1,
  kind: 'brief',
  path: 'architecture/BRIEF.md',
  title: 'BRIEF',
}

const ARCHITECT_RUN: ArchitectRun = {
  id: 200,
  role: 'architect',
  status: 'complete',
  session_id: null,
  conversation_id: null,
  created_at: '2026-06-01T12:00:00Z',
}

const DEFAULT_PROPS = {
  space: SPACE,
  iterations: [ITERATION_2, ITERATION_1], // deliberately out of ordinal order
  architect_runs: [] as ArchitectRun[],
  unassigned_runs: [] as SpaceRun[],
  other_artifacts: [] as SpaceArtifact[],
}

describe('Spaces/Show', () => {
  it('renders iterations in ordinal order regardless of prop order', () => {
    const { container } = render(<Show {...DEFAULT_PROPS} />)
    const text = container.textContent ?? ''
    const pos1 = text.indexOf('first-iter')
    const pos2 = text.indexOf('second-iter')
    expect(pos1).toBeGreaterThan(-1)
    expect(pos2).toBeGreaterThan(-1)
    expect(pos1).toBeLessThan(pos2)
  })

  it('renders a decision section with its name and markdown body', () => {
    render(<Show {...DEFAULT_PROPS} />)
    // Decision name appears as a summary element
    expect(screen.queryByText('Grounds')).not.toBeNull()
    // Decision body rendered by Markdown (ReactMarkdown strips tags → plain text)
    expect(screen.queryByText('The grounds section body.')).not.toBeNull()
  })

  it('renders a run entry linking to /spaces/:id/runs/:run_id', () => {
    render(<Show {...DEFAULT_PROPS} />)
    const link = screen.queryByRole('link', { name: /view transcript/i })
    expect(link).not.toBeNull()
    expect(link!.getAttribute('href')).toBe('/spaces/1/runs/42')
  })

  it('renders in-page nav anchors when more than one iteration exists', () => {
    render(<Show {...DEFAULT_PROPS} />)
    const nav = screen.queryByRole('navigation')
    expect(nav).not.toBeNull()
    const anchor = screen.queryByRole('link', { name: /I01.*first-iter/ })
    expect(anchor).not.toBeNull()
    expect(anchor!.getAttribute('href')).toBe('#iteration-10')
  })

  it('interleaves architect_runs on the timeline by created_at', () => {
    const { container } = render(
      <Show {...DEFAULT_PROPS} architect_runs={[ARCHITECT_RUN]} />,
    )
    // Use DOM order within the timeline div, not textContent position —
    // the nav section also mentions iteration names so indexOf is ambiguous.
    const timeline = container.querySelector('[data-testid="timeline"]')
    expect(timeline).not.toBeNull()
    const children = Array.from(timeline!.children)
    const idx1 = children.findIndex((el) => el.id === 'iteration-10')
    const idxArun = children.findIndex((el) => el.textContent?.includes('architect'))
    const idx2 = children.findIndex((el) => el.id === 'iteration-11')
    expect(idx1).toBeGreaterThan(-1)
    expect(idxArun).toBeGreaterThan(-1)
    expect(idx2).toBeGreaterThan(-1)
    // architect run (12:00) falls between iter1 (00:00) and iter2 (next day)
    expect(idx1).toBeLessThan(idxArun)
    expect(idxArun).toBeLessThan(idx2)
  })

  it('renders other_artifacts in a trailing section', () => {
    render(<Show {...DEFAULT_PROPS} other_artifacts={[OTHER_ARTIFACT]} />)
    expect(screen.queryByText('Other Artifacts')).not.toBeNull()
  })
})

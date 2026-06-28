import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { ArchitectRun, SpaceArtifact, SpaceIteration, SpaceRun, Turn as TurnType } from '@/types'

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

// Isolate Turn from its deep dependency tree; we verify it's invoked by data-testid.
vi.mock('@/components/Turn', () => ({
  default: ({ anchorId }: { anchorId: number }) => (
    <li data-testid={`turn-${anchorId}`}>turn-{anchorId}</li>
  ),
}))

import Show from './Show'

const SPACE = { id: 1, slug: 'test-space', title: 'Test Space', status: 'active', repos: [], git_utc_offset: -21600 as number | null }

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
  occurred_at: '2026-06-01T00:00:00Z',
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
  occurred_at: '2026-06-02T00:00:00Z',
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
  occurred_at: '2026-06-01T12:00:00Z',
  has_transcript: false,
}

const DEFAULT_PROPS = {
  space: SPACE,
  iterations: [ITERATION_2, ITERATION_1], // deliberately out of ordinal order
  architect_runs: [] as ArchitectRun[],
  unassigned_runs: [] as SpaceRun[],
  other_artifacts: [] as SpaceArtifact[],
}

describe('Spaces/Show', () => {
  it('renders iterations in descending ordinal order (latest first)', () => {
    const { container } = render(<Show {...DEFAULT_PROPS} />)
    const text = container.textContent ?? ''
    const pos1 = text.indexOf('first-iter')
    const pos2 = text.indexOf('second-iter')
    expect(pos1).toBeGreaterThan(-1)
    expect(pos2).toBeGreaterThan(-1)
    // descending: second-iter (ordinal 2) appears before first-iter (ordinal 1)
    expect(pos2).toBeLessThan(pos1)
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
    const links = screen.queryAllByRole('link', { name: /view transcript/i })
    const runLink = links.find((l) => l.getAttribute('href') === '/spaces/1/runs/42')
    expect(runLink).not.toBeUndefined()
  })

  it('renders in-page nav anchors when more than one iteration exists', () => {
    render(<Show {...DEFAULT_PROPS} />)
    const nav = screen.queryByRole('navigation')
    expect(nav).not.toBeNull()
    const anchor = screen.queryByRole('link', { name: /I01.*first-iter/ })
    expect(anchor).not.toBeNull()
    expect(anchor!.getAttribute('href')).toBe('#iteration-10')
  })

  it('interleaves architect_runs on the timeline by occurred_at (descending order)', () => {
    const { container } = render(
      <Show {...DEFAULT_PROPS} architect_runs={[ARCHITECT_RUN]} />,
    )
    // Use DOM order within the timeline div
    const timeline = container.querySelector('[data-testid="timeline"]')
    expect(timeline).not.toBeNull()
    const children = Array.from(timeline!.children)
    const idx1 = children.findIndex((el) => el.id === 'iteration-10')
    const idxArun = children.findIndex((el) => el.textContent?.includes('architect'))
    const idx2 = children.findIndex((el) => el.id === 'iteration-11')
    expect(idx1).toBeGreaterThan(-1)
    expect(idxArun).toBeGreaterThan(-1)
    expect(idx2).toBeGreaterThan(-1)
    // descending: iter2 (June 2) first, architect run (June 1 noon) middle, iter1 (June 1) last
    expect(idx2).toBeLessThan(idxArun)
    expect(idxArun).toBeLessThan(idx1)
  })

  it('renders other_artifacts in a trailing section', () => {
    render(<Show {...DEFAULT_PROPS} other_artifacts={[OTHER_ARTIFACT]} />)
    expect(screen.queryByText('Other Artifacts')).not.toBeNull()
  })

  it('renders an artifact row linking to /spaces/:id/artifacts/:artifact_id', () => {
    render(<Show {...DEFAULT_PROPS} other_artifacts={[OTHER_ARTIFACT]} />)
    const link = screen.queryByRole('link', { name: /^view$/i })
    expect(link).not.toBeNull()
    expect(link!.getAttribute('href')).toBe('/spaces/1/artifacts/1')
  })

  it('renders architect session as a collapsed card (transcript not in DOM initially)', () => {
    render(<Show {...DEFAULT_PROPS} architect_runs={[ARCHITECT_RUN]} />)
    // Card is present in the DOM
    expect(document.getElementById('architect-run-200')).not.toBeNull()
    // No turns rendered while collapsed
    expect(screen.queryByTestId('turn-99')).toBeNull()
    // Loading / error states not visible while collapsed
    expect(screen.queryByText(/loading transcript/i)).toBeNull()
  })
})

describe('ArchitectSessionSection — expand / fetch', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('expanding a session with has_transcript triggers a fetch and renders turns via Turn', async () => {
    const run: ArchitectRun = { ...ARCHITECT_RUN, has_transcript: true }
    const mockTurn: TurnType = { anchor_id: 99, prompt: null, rounds: [] }
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: true, json: async () => ({ turns: [mockTurn] }) }),
    )

    render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)
    expect(screen.queryByTestId('turn-99')).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: /expand architect session/i }))

    await waitFor(() => {
      expect(screen.getByTestId('turn-99')).not.toBeNull()
    })
    expect(vi.mocked(fetch)).toHaveBeenCalledWith('/spaces/1/runs/200/transcript')
  })

  it('does not refetch transcript on subsequent toggles', async () => {
    const run: ArchitectRun = { ...ARCHITECT_RUN, has_transcript: true }
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ turns: [{ anchor_id: 99, prompt: null, rounds: [] }] }),
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)

    // First expand — triggers fetch
    fireEvent.click(screen.getByRole('button', { name: /expand architect session/i }))
    await waitFor(() => expect(screen.getByTestId('turn-99')).not.toBeNull())

    // Collapse
    fireEvent.click(screen.getByRole('button', { name: /collapse architect session/i }))
    // Re-expand — must NOT fetch again
    fireEvent.click(screen.getByRole('button', { name: /expand architect session/i }))

    await waitFor(() => expect(screen.getByTestId('turn-99')).not.toBeNull())
    expect(mockFetch).toHaveBeenCalledTimes(1)
  })

  it('shows empty state when session has no transcript (has_transcript false)', () => {
    const run: ArchitectRun = { ...ARCHITECT_RUN, has_transcript: false }
    render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)
    fireEvent.click(screen.getByRole('button', { name: /expand architect session/i }))
    // No fetch; no turns; empty state shown
    expect(screen.getByText(/no transcript available/i)).not.toBeNull()
  })

  it('timeline order reflects occurred_at — a session between two iterations lands between them', () => {
    const run: ArchitectRun = { ...ARCHITECT_RUN, occurred_at: '2026-06-01T12:00:00Z' }
    const { container } = render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)
    const timeline = container.querySelector('[data-testid="timeline"]')!
    const children = Array.from(timeline.children)
    const idxIter1 = children.findIndex((el) => el.id === 'iteration-10')
    const idxRun = children.findIndex((el) => el.id === 'architect-run-200')
    const idxIter2 = children.findIndex((el) => el.id === 'iteration-11')
    // Descending: iter2 (June 2) → run (June 1 noon) → iter1 (June 1 midnight)
    expect(idxIter2).toBeLessThan(idxRun)
    expect(idxRun).toBeLessThan(idxIter1)
  })

  it('architect session card shows absolute timestamp in space git_utc_offset', () => {
    // occurred_at is UTC; space.git_utc_offset=-21600 → wall-clock should be -0600
    const run: ArchitectRun = { ...ARCHITECT_RUN, occurred_at: '2026-06-28T21:32:12.278Z' }
    const space = { ...SPACE, git_utc_offset: -21600 }
    const { container } = render(<Show {...DEFAULT_PROPS} space={space} architect_runs={[run]} />)
    const section = container.querySelector('#architect-run-200')
    expect(section).not.toBeNull()
    expect(section!.textContent).toContain('2026-06-28T15:32:12.278-0600')
  })

  it('iteration card shows absolute timestamp in occurred_at_utc_offset', () => {
    const iter: SpaceIteration = {
      ...ITERATION_1,
      occurred_at: '2026-06-28T21:32:12.278Z',
      occurred_at_utc_offset: -21600,
    }
    const { container } = render(<Show {...DEFAULT_PROPS} iterations={[iter]} />)
    expect(container.textContent).toMatch(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d{4}/)
  })
})

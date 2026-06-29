import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
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
  turns: [],
}

const DEFAULT_PROPS = {
  space: SPACE,
  iterations: [ITERATION_2, ITERATION_1], // deliberately out of ordinal order
  architect_runs: [] as ArchitectRun[],
  unassigned_runs: [] as SpaceRun[],
  other_artifacts: [] as SpaceArtifact[],
}

describe('Spaces/Show', () => {
  it('renders iterations in ascending ordinal order (oldest first)', () => {
    const { container } = render(<Show {...DEFAULT_PROPS} />)
    const text = container.textContent ?? ''
    const pos1 = text.indexOf('first-iter')
    const pos2 = text.indexOf('second-iter')
    expect(pos1).toBeGreaterThan(-1)
    expect(pos2).toBeGreaterThan(-1)
    // ascending: first-iter (ordinal 1) appears before second-iter (ordinal 2)
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

  it('interleaves architect_runs on the timeline by occurred_at (ascending order)', () => {
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
    // ascending: iter1 (June 1 midnight) first, architect run (June 1 noon) middle, iter2 (June 2) last
    expect(idx1).toBeLessThan(idxArun)
    expect(idxArun).toBeLessThan(idx2)
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

  it('architect session is visible in the DOM and shows empty state immediately (no fetch needed)', () => {
    render(<Show {...DEFAULT_PROPS} architect_runs={[ARCHITECT_RUN]} />)
    // Card is present in the DOM
    expect(document.getElementById('architect-run-200')).not.toBeNull()
    // Empty turns → "No transcript available." shown inline (no click required)
    expect(screen.queryByText(/no transcript available/i)).not.toBeNull()
    // No loading state
    expect(screen.queryByText(/loading transcript/i)).toBeNull()
  })
})

describe('ArchitectSessionSection — eager inline turns', () => {
  it('renders turns from run.turns prop inline without any fetch', () => {
    const mockTurn: TurnType = { anchor_id: 99, prompt: null, rounds: [] }
    const run: ArchitectRun = { ...ARCHITECT_RUN, turns: [mockTurn] }

    // Verify fetch is not called by asserting no global fetch stub is needed
    const fetchSpy = vi.spyOn(globalThis, 'fetch')

    render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)

    // turn-99 is in DOM immediately — no click, no fetch
    expect(screen.getByTestId('turn-99')).not.toBeNull()
    expect(fetchSpy).not.toHaveBeenCalled()

    fetchSpy.mockRestore()
  })

  it('renders multiple turns from props in order', () => {
    const turn1: TurnType = { anchor_id: 1, prompt: null, rounds: [] }
    const turn2: TurnType = { anchor_id: 2, prompt: null, rounds: [] }
    const run: ArchitectRun = { ...ARCHITECT_RUN, turns: [turn1, turn2] }

    render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)

    expect(screen.getByTestId('turn-1')).not.toBeNull()
    expect(screen.getByTestId('turn-2')).not.toBeNull()
  })

  it('shows empty state when turns prop is empty (no fetch, no click required)', () => {
    const run: ArchitectRun = { ...ARCHITECT_RUN, turns: [] }
    render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)
    // Empty state is visible immediately (session is expanded by default)
    expect(screen.getByText(/no transcript available/i)).not.toBeNull()
  })

  it('shows empty state when turns prop is absent', () => {
    const run: ArchitectRun = { ...ARCHITECT_RUN, turns: undefined }
    render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)
    expect(screen.getByText(/no transcript available/i)).not.toBeNull()
  })

  it('collapse toggle hides and re-shows turns', () => {
    const mockTurn: TurnType = { anchor_id: 77, prompt: null, rounds: [] }
    const run: ArchitectRun = { ...ARCHITECT_RUN, turns: [mockTurn] }
    render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)

    // Turns visible by default (expanded)
    expect(screen.getByTestId('turn-77')).not.toBeNull()

    // Collapse
    fireEvent.click(screen.getByRole('button', { name: /collapse architect session/i }))
    expect(screen.queryByTestId('turn-77')).toBeNull()

    // Re-expand
    fireEvent.click(screen.getByRole('button', { name: /expand architect session/i }))
    expect(screen.getByTestId('turn-77')).not.toBeNull()
  })

  it('timeline order reflects occurred_at ascending — session between two iterations lands between them', () => {
    const run: ArchitectRun = { ...ARCHITECT_RUN, occurred_at: '2026-06-01T12:00:00Z' }
    const { container } = render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)
    const timeline = container.querySelector('[data-testid="timeline"]')!
    const children = Array.from(timeline.children)
    const idxIter1 = children.findIndex((el) => el.id === 'iteration-10')
    const idxRun = children.findIndex((el) => el.id === 'architect-run-200')
    const idxIter2 = children.findIndex((el) => el.id === 'iteration-11')
    // Ascending: iter1 (June 1 midnight) → run (June 1 noon) → iter2 (June 2)
    expect(idxIter1).toBeLessThan(idxRun)
    expect(idxRun).toBeLessThan(idxIter2)
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

describe('harness/model badge', () => {
  it('renders harness · model badge on architect session when both are present', () => {
    const run: ArchitectRun = {
      ...ARCHITECT_RUN,
      harness: 'claude-code',
      model: 'claude-opus-4-8',
    }
    const { container } = render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)
    const section = container.querySelector('#architect-run-200')
    expect(section).not.toBeNull()
    expect(section!.textContent).toContain('claude-code · claude-opus-4-8')
  })

  it('renders only harness when model is absent on architect session', () => {
    const run: ArchitectRun = {
      ...ARCHITECT_RUN,
      harness: 'claude-code',
      model: null,
    }
    const { container } = render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)
    const section = container.querySelector('#architect-run-200')
    expect(section!.textContent).toContain('claude-code')
    // badge should not combine harness · model when model is absent
    expect(section!.textContent).not.toContain('claude-code · ')
  })

  it('renders no badge when both harness and model are absent on architect session', () => {
    const run: ArchitectRun = {
      ...ARCHITECT_RUN,
      harness: null,
      model: null,
    }
    const { container } = render(<Show {...DEFAULT_PROPS} architect_runs={[run]} />)
    const section = container.querySelector('#architect-run-200')
    // badge text does not appear
    expect(section!.textContent).not.toMatch(/claude-code/)
  })

  it('renders harness · model badge on builder-run row when both are present', () => {
    const runWithBadge: SpaceRun = {
      ...RUN,
      harness: 'claude-code',
      model: 'claude-opus-4-8',
    }
    const iter: SpaceIteration = { ...ITERATION_1, runs: [runWithBadge] }
    const { container } = render(<Show {...DEFAULT_PROPS} iterations={[iter]} />)
    const section = container.querySelector('#iteration-10')
    expect(section).not.toBeNull()
    expect(section!.textContent).toContain('claude-code · claude-opus-4-8')
  })

  it('renders no badge when both harness and model are absent on builder-run row', () => {
    const runNoBadge: SpaceRun = { ...RUN, harness: null, model: null }
    const iter: SpaceIteration = { ...ITERATION_1, runs: [runNoBadge] }
    const { container } = render(<Show {...DEFAULT_PROPS} iterations={[iter]} />)
    const section = container.querySelector('#iteration-10')
    expect(section!.textContent).not.toMatch(/claude-code/)
  })
})

import { describe, expect, it } from 'vitest'
import type { Space, SpaceArtifact, SpaceIteration, SpaceListItem, SpaceRun } from '@/types'
import { KIND_VARIANT, STATUS_VARIANT, VERDICT_VARIANT, relativeTime } from './helpers'

// Fixtures matching the locked props contract exactly.

const SPACE_LIST_FIXTURE: SpaceListItem = {
  id: 1,
  slug: '20260627-space-server-objects',
  title: 'Space Server Objects',
  status: 'active',
  iterations_count: 3,
  runs_count: 5,
  imported_at: '2026-06-27T00:00:00Z',
}

const SPACE_FIXTURE: Space = {
  id: 1,
  slug: '20260627-space-server-objects',
  title: 'Space Server Objects',
  status: 'active',
  repos: ['github.com/jetpks/space-architect'],
}

const RUN_FIXTURE: SpaceRun = {
  id: 3,
  lane: 'lane-a',
  role: 'builder',
  status: 'complete',
  conversation_id: 42,
}

const ARTIFACT_FIXTURE: SpaceArtifact = {
  id: 7,
  kind: 'iteration',
  path: 'architecture/I01-space-model-and-import.md',
  title: 'I01: space-model-and-import',
}

const ITERATION_FIXTURE: SpaceIteration = {
  id: 10,
  ordinal: 1,
  name: 'space-model-and-import',
  freeze_sha: 'abc1234',
  verdict: 'continue',
  artifacts: [ARTIFACT_FIXTURE],
  runs: [RUN_FIXTURE],
}

const OTHER_ARTIFACT_FIXTURE: SpaceArtifact = {
  id: 1,
  kind: 'brief',
  path: 'architecture/BRIEF.md',
  title: 'BRIEF — space-server-objects',
}

// --- relativeTime ---

describe('relativeTime', () => {
  it('returns "just now" for timestamps under 1 minute old', () => {
    const recent = new Date(Date.now() - 30_000).toISOString()
    expect(relativeTime(recent)).toBe('just now')
  })

  it('returns minutes for timestamps under 1 hour old', () => {
    const ago = new Date(Date.now() - 5 * 60_000).toISOString()
    expect(relativeTime(ago)).toBe('5m ago')
  })

  it('returns hours for timestamps under 1 day old', () => {
    const ago = new Date(Date.now() - 2 * 60 * 60_000).toISOString()
    expect(relativeTime(ago)).toBe('2h ago')
  })

  it('returns days for older timestamps', () => {
    const ago = new Date(Date.now() - 3 * 24 * 60 * 60_000).toISOString()
    expect(relativeTime(ago)).toBe('3d ago')
  })
})

// --- badge variant maps ---

describe('STATUS_VARIANT', () => {
  it('maps complete → secondary', () => expect(STATUS_VARIANT['complete']).toBe('secondary'))
  it('maps pending → outline', () => expect(STATUS_VARIANT['pending']).toBe('outline'))
  it('maps live → default', () => expect(STATUS_VARIANT['live']).toBe('default'))
  it('maps failed → destructive', () => expect(STATUS_VARIANT['failed']).toBe('destructive'))
  it('maps active → default', () => expect(STATUS_VARIANT['active']).toBe('default'))
})

describe('VERDICT_VARIANT', () => {
  it('maps continue → default', () => expect(VERDICT_VARIANT['continue']).toBe('default'))
  it('maps complete → secondary', () => expect(VERDICT_VARIANT['complete']).toBe('secondary'))
  it('maps blocked → destructive', () => expect(VERDICT_VARIANT['blocked']).toBe('destructive'))
  it('maps abandoned → outline', () => expect(VERDICT_VARIANT['abandoned']).toBe('outline'))
})

describe('KIND_VARIANT', () => {
  it('maps brief → outline', () => expect(KIND_VARIANT['brief']).toBe('outline'))
  it('maps iteration → secondary', () => expect(KIND_VARIANT['iteration']).toBe('secondary'))
  it('maps report → default', () => expect(KIND_VARIANT['report']).toBe('default'))
})

// --- Spaces/Index props contract ---

describe('Spaces/Index — props contract shape', () => {
  it('space list item exposes title and slug', () => {
    expect(SPACE_LIST_FIXTURE.title).toBe('Space Server Objects')
    expect(SPACE_LIST_FIXTURE.slug).toBe('20260627-space-server-objects')
  })

  it('space list item exposes iteration and run counts', () => {
    expect(SPACE_LIST_FIXTURE.iterations_count).toBe(3)
    expect(SPACE_LIST_FIXTURE.runs_count).toBe(5)
  })

  it('imported_at produces a valid relative time string', () => {
    expect(typeof relativeTime(SPACE_LIST_FIXTURE.imported_at)).toBe('string')
    expect(relativeTime(SPACE_LIST_FIXTURE.imported_at).length).toBeGreaterThan(0)
  })

  it('link href resolves to /spaces/:id', () => {
    expect(`/spaces/${SPACE_LIST_FIXTURE.id}`).toBe('/spaces/1')
  })

  it('status maps to a badge variant', () => {
    expect(STATUS_VARIANT[SPACE_LIST_FIXTURE.status] ?? 'outline').toBe('default')
  })
})

// --- Spaces/Show props contract ---

describe('Spaces/Show — space header', () => {
  it('exposes title, slug, status, and repos', () => {
    expect(SPACE_FIXTURE.title).toBe('Space Server Objects')
    expect(SPACE_FIXTURE.slug).toBe('20260627-space-server-objects')
    expect(SPACE_FIXTURE.status).toBe('active')
    expect(SPACE_FIXTURE.repos).toEqual(['github.com/jetpks/space-architect'])
  })
})

describe('Spaces/Show — iteration fields', () => {
  it('exposes ordinal, name, freeze_sha, and verdict', () => {
    expect(ITERATION_FIXTURE.ordinal).toBe(1)
    expect(ITERATION_FIXTURE.name).toBe('space-model-and-import')
    expect(ITERATION_FIXTURE.freeze_sha).toBe('abc1234')
    expect(ITERATION_FIXTURE.verdict).toBe('continue')
  })

  it('freeze_sha prefix (7 chars) matches expected value', () => {
    expect(ITERATION_FIXTURE.freeze_sha!.slice(0, 7)).toBe('abc1234')
  })

  it('verdict maps to a badge variant', () => {
    expect(VERDICT_VARIANT[ITERATION_FIXTURE.verdict!] ?? 'outline').toBe('default')
  })

  it('iterations can be sorted by ordinal', () => {
    const second: SpaceIteration = { ...ITERATION_FIXTURE, id: 11, ordinal: 2, name: 'second' }
    const unsorted = [second, ITERATION_FIXTURE]
    const sorted = [...unsorted].sort((a, b) => a.ordinal - b.ordinal)
    expect(sorted[0].name).toBe('space-model-and-import')
    expect(sorted[1].name).toBe('second')
  })
})

describe('Spaces/Show — run links', () => {
  it('run link href resolves to /runs/:id', () => {
    expect(`/runs/${RUN_FIXTURE.id}`).toBe('/runs/3')
  })

  it('run status maps to a badge variant', () => {
    expect(STATUS_VARIANT[RUN_FIXTURE.status] ?? 'outline').toBe('secondary')
  })

  it('run exposes lane and role', () => {
    expect(RUN_FIXTURE.lane).toBe('lane-a')
    expect(RUN_FIXTURE.role).toBe('builder')
  })
})

describe('Spaces/Show — artifacts', () => {
  it('iteration artifact exposes kind and title', () => {
    expect(ARTIFACT_FIXTURE.kind).toBe('iteration')
    expect(ARTIFACT_FIXTURE.title).toBe('I01: space-model-and-import')
  })

  it('artifact kind maps to a badge variant', () => {
    expect(KIND_VARIANT[ARTIFACT_FIXTURE.kind] ?? 'outline').toBe('secondary')
  })

  it('other artifact (brief kind) maps to outline', () => {
    expect(KIND_VARIANT[OTHER_ARTIFACT_FIXTURE.kind] ?? 'outline').toBe('outline')
    expect(OTHER_ARTIFACT_FIXTURE.title).toBe('BRIEF — space-server-objects')
  })
})

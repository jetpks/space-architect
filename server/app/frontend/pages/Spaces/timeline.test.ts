import { describe, expect, it } from 'vitest'
import type { ArchitectRun, SpaceIteration } from '@/types'
import { interleaveTimeline, sortIterationsByOrdinal } from './timeline'

const BASE_ITER: SpaceIteration = {
  id: 1,
  ordinal: 1,
  name: 'first',
  freeze_sha: null,
  verdict: null,
  artifacts: [],
  runs: [],
}

const BASE_ARUN: ArchitectRun = {
  id: 100,
  role: 'architect',
  status: 'complete',
  session_id: null,
  conversation_id: null,
  created_at: '2026-01-02T00:00:00Z',
}

// --- sortIterationsByOrdinal ---

describe('sortIterationsByOrdinal', () => {
  it('returns iterations sorted by ordinal descending (latest first)', () => {
    const a: SpaceIteration = { ...BASE_ITER, id: 2, ordinal: 2, name: 'second' }
    const b: SpaceIteration = { ...BASE_ITER, id: 1, ordinal: 1, name: 'first' }
    const sorted = sortIterationsByOrdinal([a, b])
    expect(sorted[0].name).toBe('second')
    expect(sorted[1].name).toBe('first')
  })

  it('does not mutate the input array', () => {
    const a: SpaceIteration = { ...BASE_ITER, id: 2, ordinal: 2, name: 'second' }
    const b: SpaceIteration = { ...BASE_ITER, id: 1, ordinal: 1, name: 'first' }
    const input = [a, b]
    sortIterationsByOrdinal(input)
    expect(input[0].name).toBe('second')
  })

  it('handles a single iteration', () => {
    const result = sortIterationsByOrdinal([BASE_ITER])
    expect(result).toHaveLength(1)
    expect(result[0].ordinal).toBe(1)
  })
})

// --- interleaveTimeline ---

describe('interleaveTimeline', () => {
  it('returns iterations in descending ordinal order when no architect runs', () => {
    const iter1: SpaceIteration = { ...BASE_ITER, id: 1, ordinal: 1, name: 'first' }
    const iter2: SpaceIteration = { ...BASE_ITER, id: 2, ordinal: 2, name: 'second' }
    const result = interleaveTimeline([iter1, iter2], [])
    expect(result[0].type).toBe('iteration')
    expect((result[0] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('second')
    expect(result[1].type).toBe('iteration')
    expect((result[1] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('first')
  })

  it('interleaves architect run between iterations by occurred_at (the bug fix: real instant, not import-time stamp)', () => {
    const iter1: SpaceIteration = {
      ...BASE_ITER,
      id: 1,
      ordinal: 1,
      name: 'first',
      occurred_at: '2026-01-01T00:00:00Z',
    }
    const iter2: SpaceIteration = {
      ...BASE_ITER,
      id: 2,
      ordinal: 2,
      name: 'second',
      occurred_at: '2026-01-03T00:00:00Z',
    }
    const arun: ArchitectRun = { ...BASE_ARUN, occurred_at: '2026-01-02T00:00:00Z' }
    // Descending order: iter2 (Jan 3), arun (Jan 2), iter1 (Jan 1)
    const result = interleaveTimeline([iter2, iter1], [arun])
    expect(result).toHaveLength(3)
    expect(result[0].type).toBe('iteration')
    expect((result[0] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('second')
    expect(result[1].type).toBe('architect_run')
    expect(result[2].type).toBe('iteration')
    expect((result[2] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('first')
  })

  it('places architect run after all iterations when it predates them', () => {
    const iter: SpaceIteration = {
      ...BASE_ITER,
      occurred_at: '2026-06-01T00:00:00Z',
    }
    const arun: ArchitectRun = { ...BASE_ARUN, occurred_at: '2026-01-01T00:00:00Z' }
    // arun (Jan 1) predates iter (June 1) — in descending timeline it falls to the bottom
    const result = interleaveTimeline([iter], [arun])
    expect(result[0].type).toBe('iteration')
    expect(result[1].type).toBe('architect_run')
  })

  it('places architect run before all iterations when it postdates them', () => {
    const iter: SpaceIteration = {
      ...BASE_ITER,
      occurred_at: '2026-01-01T00:00:00Z',
    }
    const arun: ArchitectRun = { ...BASE_ARUN, occurred_at: '2026-06-01T00:00:00Z' }
    // arun (June 1) postdates iter (Jan 1) — in descending timeline it floats to the top
    const result = interleaveTimeline([iter], [arun])
    expect(result[0].type).toBe('architect_run')
    expect(result[1].type).toBe('iteration')
  })

  it('appends architect run when iterations lack occurred_at (graceful fallback)', () => {
    const iter: SpaceIteration = { ...BASE_ITER }
    const arun: ArchitectRun = { ...BASE_ARUN, occurred_at: '2026-01-01T00:00:00Z' }
    const result = interleaveTimeline([iter], [arun])
    expect(result[0].type).toBe('iteration')
    expect(result[1].type).toBe('architect_run')
  })

  it('appends architect run to end when run occurred_at is null (graceful fallback)', () => {
    const iter: SpaceIteration = { ...BASE_ITER, occurred_at: '2026-06-01T00:00:00Z' }
    const arun: ArchitectRun = { ...BASE_ARUN, occurred_at: null }
    const result = interleaveTimeline([iter], [arun])
    expect(result[0].type).toBe('iteration')
    expect(result[1].type).toBe('architect_run')
  })

  it('sorts multiple architect runs by occurred_at descending before interleaving', () => {
    const iter1: SpaceIteration = {
      ...BASE_ITER,
      id: 1,
      ordinal: 1,
      occurred_at: '2026-01-05T00:00:00Z',
    }
    const arunA: ArchitectRun = { ...BASE_ARUN, id: 200, occurred_at: '2026-01-02T00:00:00Z' }
    const arunB: ArchitectRun = { ...BASE_ARUN, id: 201, occurred_at: '2026-01-01T00:00:00Z' }
    // iter1 (Jan 5) is most recent; arunA (Jan 2) and arunB (Jan 1) predate it → fall below
    const result = interleaveTimeline([iter1], [arunA, arunB])
    expect(result[0].type).toBe('iteration')
    expect(result[1].type).toBe('architect_run')
    expect((result[1] as { type: 'architect_run'; data: ArchitectRun }).data.id).toBe(200)
    expect(result[2].type).toBe('architect_run')
    expect((result[2] as { type: 'architect_run'; data: ArchitectRun }).data.id).toBe(201)
  })

  it('orders multiple sessions correctly when some fall above and some below an iteration', () => {
    const iter: SpaceIteration = { ...BASE_ITER, ordinal: 1, occurred_at: '2026-01-10T00:00:00Z' }
    const arunAbove: ArchitectRun = { ...BASE_ARUN, id: 202, occurred_at: '2026-01-15T00:00:00Z' }
    const arunBelow1: ArchitectRun = { ...BASE_ARUN, id: 200, occurred_at: '2026-01-08T00:00:00Z' }
    const arunBelow2: ArchitectRun = { ...BASE_ARUN, id: 201, occurred_at: '2026-01-05T00:00:00Z' }
    // Descending: arunAbove (Jan 15), iter (Jan 10), arunBelow1 (Jan 8), arunBelow2 (Jan 5)
    const result = interleaveTimeline([iter], [arunBelow1, arunBelow2, arunAbove])
    expect(result).toHaveLength(4)
    expect(result[0].type).toBe('architect_run')
    expect((result[0] as { type: 'architect_run'; data: ArchitectRun }).data.id).toBe(202)
    expect(result[1].type).toBe('iteration')
    expect(result[2].type).toBe('architect_run')
    expect((result[2] as { type: 'architect_run'; data: ArchitectRun }).data.id).toBe(200)
    expect(result[3].type).toBe('architect_run')
    expect((result[3] as { type: 'architect_run'; data: ArchitectRun }).data.id).toBe(201)
  })

  it('tie-break: equal occurred_at places run before iteration (stable order)', () => {
    const iter: SpaceIteration = { ...BASE_ITER, occurred_at: '2026-01-01T12:00:00Z' }
    const arun: ArchitectRun = { ...BASE_ARUN, occurred_at: '2026-01-01T12:00:00Z' }
    const result = interleaveTimeline([iter], [arun])
    expect(result[0].type).toBe('architect_run')
    expect(result[1].type).toBe('iteration')
  })
})

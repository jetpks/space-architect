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
  it('returns iterations sorted by ordinal ascending (oldest first)', () => {
    const a: SpaceIteration = { ...BASE_ITER, id: 2, ordinal: 2, name: 'second' }
    const b: SpaceIteration = { ...BASE_ITER, id: 1, ordinal: 1, name: 'first' }
    const sorted = sortIterationsByOrdinal([a, b])
    expect(sorted[0].name).toBe('first')
    expect(sorted[1].name).toBe('second')
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
  it('returns iterations in ascending ordinal order (oldest first) when no architect runs', () => {
    const iter1: SpaceIteration = { ...BASE_ITER, id: 1, ordinal: 1, name: 'first' }
    const iter2: SpaceIteration = { ...BASE_ITER, id: 2, ordinal: 2, name: 'second' }
    const result = interleaveTimeline([iter2, iter1], [])
    expect(result[0].type).toBe('iteration')
    expect((result[0] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('first')
    expect(result[1].type).toBe('iteration')
    expect((result[1] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('second')
  })

  it('interleaves architect run between iterations by occurred_at (ascending: oldest → newest)', () => {
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
    // Ascending order: iter1 (Jan 1), arun (Jan 2), iter2 (Jan 3)
    const result = interleaveTimeline([iter2, iter1], [arun])
    expect(result).toHaveLength(3)
    expect(result[0].type).toBe('iteration')
    expect((result[0] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('first')
    expect(result[1].type).toBe('architect_run')
    expect(result[2].type).toBe('iteration')
    expect((result[2] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('second')
  })

  it('places architect run before all iterations when it predates them (oldest first)', () => {
    const iter: SpaceIteration = {
      ...BASE_ITER,
      occurred_at: '2026-06-01T00:00:00Z',
    }
    const arun: ArchitectRun = { ...BASE_ARUN, occurred_at: '2026-01-01T00:00:00Z' }
    // arun (Jan 1) predates iter (June 1) — in ascending timeline it floats to the top
    const result = interleaveTimeline([iter], [arun])
    expect(result[0].type).toBe('architect_run')
    expect(result[1].type).toBe('iteration')
  })

  it('places architect run after all iterations when it postdates them', () => {
    const iter: SpaceIteration = {
      ...BASE_ITER,
      occurred_at: '2026-01-01T00:00:00Z',
    }
    const arun: ArchitectRun = { ...BASE_ARUN, occurred_at: '2026-06-01T00:00:00Z' }
    // arun (June 1) postdates iter (Jan 1) — in ascending timeline it falls to the bottom
    const result = interleaveTimeline([iter], [arun])
    expect(result[0].type).toBe('iteration')
    expect(result[1].type).toBe('architect_run')
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

  it('sorts multiple architect runs by occurred_at ascending before interleaving', () => {
    const iter1: SpaceIteration = {
      ...BASE_ITER,
      id: 1,
      ordinal: 1,
      occurred_at: '2026-01-05T00:00:00Z',
    }
    const arunA: ArchitectRun = { ...BASE_ARUN, id: 200, occurred_at: '2026-01-02T00:00:00Z' }
    const arunB: ArchitectRun = { ...BASE_ARUN, id: 201, occurred_at: '2026-01-01T00:00:00Z' }
    // Ascending: arunB (Jan 1), arunA (Jan 2), iter1 (Jan 5)
    const result = interleaveTimeline([iter1], [arunA, arunB])
    expect(result[0].type).toBe('architect_run')
    expect((result[0] as { type: 'architect_run'; data: ArchitectRun }).data.id).toBe(201)
    expect(result[1].type).toBe('architect_run')
    expect((result[1] as { type: 'architect_run'; data: ArchitectRun }).data.id).toBe(200)
    expect(result[2].type).toBe('iteration')
  })

  it('orders multiple sessions correctly when some fall above and some below an iteration', () => {
    const iter: SpaceIteration = { ...BASE_ITER, ordinal: 1, occurred_at: '2026-01-10T00:00:00Z' }
    const arunAbove: ArchitectRun = { ...BASE_ARUN, id: 202, occurred_at: '2026-01-15T00:00:00Z' }
    const arunBelow1: ArchitectRun = { ...BASE_ARUN, id: 200, occurred_at: '2026-01-08T00:00:00Z' }
    const arunBelow2: ArchitectRun = { ...BASE_ARUN, id: 201, occurred_at: '2026-01-05T00:00:00Z' }
    // Ascending: arunBelow2 (Jan 5), arunBelow1 (Jan 8), iter (Jan 10), arunAbove (Jan 15)
    const result = interleaveTimeline([iter], [arunBelow1, arunBelow2, arunAbove])
    expect(result).toHaveLength(4)
    expect(result[0].type).toBe('architect_run')
    expect((result[0] as { type: 'architect_run'; data: ArchitectRun }).data.id).toBe(201)
    expect(result[1].type).toBe('architect_run')
    expect((result[1] as { type: 'architect_run'; data: ArchitectRun }).data.id).toBe(200)
    expect(result[2].type).toBe('iteration')
    expect(result[3].type).toBe('architect_run')
    expect((result[3] as { type: 'architect_run'; data: ArchitectRun }).data.id).toBe(202)
  })

  it('tie-break: equal occurred_at places iteration before run (stable order)', () => {
    const iter: SpaceIteration = { ...BASE_ITER, occurred_at: '2026-01-01T12:00:00Z' }
    const arun: ArchitectRun = { ...BASE_ARUN, occurred_at: '2026-01-01T12:00:00Z' }
    const result = interleaveTimeline([iter], [arun])
    expect(result[0].type).toBe('iteration')
    expect(result[1].type).toBe('architect_run')
  })
})

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
  it('returns iterations sorted by ordinal ascending', () => {
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
  it('returns iterations in ordinal order when no architect runs', () => {
    const iter1: SpaceIteration = { ...BASE_ITER, id: 1, ordinal: 1, name: 'first' }
    const iter2: SpaceIteration = { ...BASE_ITER, id: 2, ordinal: 2, name: 'second' }
    const result = interleaveTimeline([iter2, iter1], [])
    expect(result[0].type).toBe('iteration')
    expect((result[0] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('first')
    expect(result[1].type).toBe('iteration')
    expect((result[1] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('second')
  })

  it('interleaves architect run between iterations by created_at', () => {
    const iter1: SpaceIteration = {
      ...BASE_ITER,
      id: 1,
      ordinal: 1,
      name: 'first',
      created_at: '2026-01-01T00:00:00Z',
    }
    const iter2: SpaceIteration = {
      ...BASE_ITER,
      id: 2,
      ordinal: 2,
      name: 'second',
      created_at: '2026-01-03T00:00:00Z',
    }
    const arun: ArchitectRun = { ...BASE_ARUN, created_at: '2026-01-02T00:00:00Z' }
    const result = interleaveTimeline([iter2, iter1], [arun])
    expect(result).toHaveLength(3)
    expect(result[0].type).toBe('iteration')
    expect(result[1].type).toBe('architect_run')
    expect(result[2].type).toBe('iteration')
  })

  it('places architect run before all iterations when it predates them', () => {
    const iter: SpaceIteration = {
      ...BASE_ITER,
      created_at: '2026-06-01T00:00:00Z',
    }
    const arun: ArchitectRun = { ...BASE_ARUN, created_at: '2026-01-01T00:00:00Z' }
    const result = interleaveTimeline([iter], [arun])
    expect(result[0].type).toBe('architect_run')
    expect(result[1].type).toBe('iteration')
  })

  it('appends architect run after all iterations when it postdates them', () => {
    const iter: SpaceIteration = {
      ...BASE_ITER,
      created_at: '2026-01-01T00:00:00Z',
    }
    const arun: ArchitectRun = { ...BASE_ARUN, created_at: '2026-06-01T00:00:00Z' }
    const result = interleaveTimeline([iter], [arun])
    expect(result[0].type).toBe('iteration')
    expect(result[1].type).toBe('architect_run')
  })

  it('appends architect run when iterations lack created_at', () => {
    const iter: SpaceIteration = { ...BASE_ITER }
    const arun: ArchitectRun = { ...BASE_ARUN, created_at: '2026-01-01T00:00:00Z' }
    const result = interleaveTimeline([iter], [arun])
    expect(result[0].type).toBe('iteration')
    expect(result[1].type).toBe('architect_run')
  })

  it('sorts multiple architect runs by created_at before interleaving', () => {
    const iter1: SpaceIteration = {
      ...BASE_ITER,
      id: 1,
      ordinal: 1,
      created_at: '2026-01-05T00:00:00Z',
    }
    const arunA: ArchitectRun = { ...BASE_ARUN, id: 200, created_at: '2026-01-02T00:00:00Z' }
    const arunB: ArchitectRun = { ...BASE_ARUN, id: 201, created_at: '2026-01-01T00:00:00Z' }
    const result = interleaveTimeline([iter1], [arunA, arunB])
    expect(result[0].type).toBe('architect_run')
    expect((result[0] as { type: 'architect_run'; data: ArchitectRun }).data.id).toBe(201)
    expect(result[1].type).toBe('architect_run')
    expect((result[1] as { type: 'architect_run'; data: ArchitectRun }).data.id).toBe(200)
    expect(result[2].type).toBe('iteration')
  })
})

import type { ArchitectRun, SpaceIteration } from '@/types'

export type TimelineItem =
  | { type: 'iteration'; data: SpaceIteration }
  | { type: 'architect_run'; data: ArchitectRun }

export function sortIterationsByOrdinal(iterations: SpaceIteration[]): SpaceIteration[] {
  return [...iterations].sort((a, b) => b.ordinal - a.ordinal)
}

// Merge iterations (descending ordinal) and architect_runs into a single timeline.
// A run whose occurred_at postdates an iteration's occurred_at appears above that
// iteration (earlier in the descending list). Runs that predate all iterations
// fall to the bottom. Runs without occurred_at flush to end.
// TIES: equal occurred_at → run appears before iteration (stable, documented order).
export function interleaveTimeline(
  iterations: SpaceIteration[],
  architectRuns: ArchitectRun[],
): TimelineItem[] {
  const sorted = sortIterationsByOrdinal(iterations)
  const result: TimelineItem[] = []

  // Sort runs by occurred_at descending; runs without occurred_at go to the end.
  const pending = [...architectRuns].sort((a, b) => {
    if (a.occurred_at == null && b.occurred_at == null) return 0
    if (a.occurred_at == null) return 1
    if (b.occurred_at == null) return -1
    return new Date(b.occurred_at).getTime() - new Date(a.occurred_at).getTime()
  })

  let runIdx = 0

  for (const iter of sorted) {
    // Insert any architect runs at or more recent than this iteration's occurred_at;
    // they belong above it in the descending timeline.
    // If the iteration has no occurred_at we can't compare, so skip insertion.
    while (runIdx < pending.length && iter.occurred_at != null) {
      const runTime = pending[runIdx].occurred_at
      if (runTime != null && new Date(runTime) >= new Date(iter.occurred_at)) {
        result.push({ type: 'architect_run', data: pending[runIdx++] })
      } else {
        break
      }
    }
    result.push({ type: 'iteration', data: iter })
  }

  // Append any remaining architect runs (they predate all iterations, or have no occurred_at).
  while (runIdx < pending.length) {
    result.push({ type: 'architect_run', data: pending[runIdx++] })
  }

  return result
}

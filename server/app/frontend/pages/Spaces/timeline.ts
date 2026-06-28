import type { ArchitectRun, SpaceIteration } from '@/types'

export type TimelineItem =
  | { type: 'iteration'; data: SpaceIteration }
  | { type: 'architect_run'; data: ArchitectRun }

export function sortIterationsByOrdinal(iterations: SpaceIteration[]): SpaceIteration[] {
  return [...iterations].sort((a, b) => b.ordinal - a.ordinal)
}

// Merge iterations (descending ordinal) and architect_runs into a single timeline.
// A run whose created_at postdates an iteration's created_at appears above that
// iteration (earlier in the descending list). Runs that predate all iterations
// fall to the bottom. Iterations without created_at flush remaining runs to end.
export function interleaveTimeline(
  iterations: SpaceIteration[],
  architectRuns: ArchitectRun[],
): TimelineItem[] {
  const sorted = sortIterationsByOrdinal(iterations)
  const result: TimelineItem[] = []
  const pending = [...architectRuns].sort(
    (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime(),
  )
  let runIdx = 0

  for (const iter of sorted) {
    // Insert any architect runs more recent than this iteration's created_at;
    // they belong above it in the descending timeline.
    // If the iteration has no created_at we can't compare, so skip insertion.
    while (runIdx < pending.length && iter.created_at != null) {
      if (new Date(pending[runIdx].created_at) > new Date(iter.created_at)) {
        result.push({ type: 'architect_run', data: pending[runIdx++] })
      } else {
        break
      }
    }
    result.push({ type: 'iteration', data: iter })
  }

  // Append any remaining architect runs (they predate all iterations).
  while (runIdx < pending.length) {
    result.push({ type: 'architect_run', data: pending[runIdx++] })
  }

  return result
}

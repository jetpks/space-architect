import type { ArchitectRun, SpaceIteration } from '@/types'

export type TimelineItem =
  | { type: 'iteration'; data: SpaceIteration }
  | { type: 'architect_run'; data: ArchitectRun }

export function sortIterationsByOrdinal(iterations: SpaceIteration[]): SpaceIteration[] {
  return [...iterations].sort((a, b) => a.ordinal - b.ordinal)
}

// Merge sorted iterations and architect_runs into a single timeline ordered by
// created_at. Iterations without created_at are kept in ordinal position (the
// architect_runs that can't be placed before them fall through to the end).
export function interleaveTimeline(
  iterations: SpaceIteration[],
  architectRuns: ArchitectRun[],
): TimelineItem[] {
  const sorted = sortIterationsByOrdinal(iterations)
  const result: TimelineItem[] = []
  const pending = [...architectRuns].sort(
    (a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime(),
  )
  let runIdx = 0

  for (const iter of sorted) {
    // Insert any architect runs whose created_at predates this iteration's.
    // If the iteration has no created_at we can't compare, so skip insertion.
    while (runIdx < pending.length && iter.created_at != null) {
      if (new Date(pending[runIdx].created_at) < new Date(iter.created_at)) {
        result.push({ type: 'architect_run', data: pending[runIdx++] })
      } else {
        break
      }
    }
    result.push({ type: 'iteration', data: iter })
  }

  // Append any remaining architect runs after all iterations.
  while (runIdx < pending.length) {
    result.push({ type: 'architect_run', data: pending[runIdx++] })
  }

  return result
}

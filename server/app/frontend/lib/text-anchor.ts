import type { Selector } from '@/types'

// Build and re-anchor the text-range selectors behind range annotations. A
// selector is captured from a message's rendered text (container.textContent)
// and re-anchored against the same rendered text on a later visit — never
// against the raw markdown source, so renderer tweaks don't strand old notes as
// long as the visible text survives. Pure string work, node-testable; the thin
// DOM layer that produces/consumes offsets lives in lib/dom-range.

// How much surrounding context to quote on each side — enough to disambiguate
// a repeated phrase without bloating the stored selector.
const CONTEXT = 32

export function buildSelector(text: string, start: number, end: number): Selector {
  return {
    exact: text.slice(start, end),
    prefix: text.slice(Math.max(0, start - CONTEXT), start),
    suffix: text.slice(end, end + CONTEXT),
    position: start,
  }
}

// Find the selector's quoted passage in `text`: every occurrence of `exact` is
// a candidate, scored by how much of the stored prefix/suffix context agrees
// with the text around it, position distance breaking ties. Null when the
// quote no longer occurs — the caller degrades to showing the note unanchored.
export function resolveSelector(
  text: string,
  selector: Selector,
): { start: number; end: number } | null {
  if (!selector.exact) return null

  const candidates: number[] = []
  for (let i = text.indexOf(selector.exact); i !== -1; i = text.indexOf(selector.exact, i + 1)) {
    candidates.push(i)
  }
  if (candidates.length === 0) return null

  const position = selector.position ?? 0
  const best = candidates.reduce((a, b) => {
    const diff = contextScore(text, b, selector) - contextScore(text, a, selector)
    if (diff !== 0) return diff > 0 ? b : a
    return Math.abs(b - position) < Math.abs(a - position) ? b : a
  })
  return { start: best, end: best + selector.exact.length }
}

// Contiguous agreement between the stored context and the text around a
// candidate: common suffix of `prefix` against what precedes it, plus common
// prefix of `suffix` against what follows. Contiguous (not fuzzy) so a
// coincidental one-char match deep in the context can't outvote the real spot.
function contextScore(text: string, start: number, selector: Selector): number {
  const { prefix, suffix, exact } = selector
  let score = 0
  for (let i = 0; i < prefix.length; i++) {
    if (text[start - 1 - i] !== prefix[prefix.length - 1 - i]) break
    score++
  }
  const end = start + exact.length
  for (let i = 0; i < suffix.length; i++) {
    if (text[end + i] !== suffix[i]) break
    score++
  }
  return score
}

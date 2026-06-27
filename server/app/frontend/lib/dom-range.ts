// The thin DOM layer between live selections/highlights and the pure selector
// math in lib/text-anchor: a DOM Range maps to character offsets in a message
// container's textContent and back. Kept tiny and dumb — everything testable
// lives in text-anchor.

// The rendered-content container a node sits in, or null when the node is
// outside one. This is the blocks div inside a Message — NOT the whole
// `message-<id>` element — so selectors never see the annotation list's own
// quoted text (a note quoting "the" must not become the best match for "the"),
// the header label, or the source view.
export function owningContentEl(node: Node): HTMLElement | null {
  const el = node instanceof Element ? node : node.parentElement
  return el?.closest<HTMLElement>('[data-message-content]') ?? null
}

export function messageIdOf(el: HTMLElement): number {
  return Number(el.dataset.messageContent)
}

// A Range's character offsets within container.textContent. Measured by
// extending a range from the container's start to each boundary and reading
// its text length — boundary-type agnostic (text node or element offsets).
export function rangeToOffsets(
  container: Element,
  range: Range,
): { start: number; end: number } | null {
  if (!container.contains(range.startContainer) || !container.contains(range.endContainer)) {
    return null
  }
  const probe = document.createRange()
  probe.selectNodeContents(container)
  probe.setEnd(range.startContainer, range.startOffset)
  const start = probe.toString().length
  probe.setEnd(range.endContainer, range.endOffset)
  const end = probe.toString().length
  return start < end ? { start, end } : null
}

// The inverse: character offsets back to a live Range over the container's
// text nodes. Null when the offsets run past the text (content changed).
export function offsetsToRange(container: Element, start: number, end: number): Range | null {
  const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT)
  const range = document.createRange()
  let total = 0
  let startSet = false
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const length = (node.textContent ?? '').length
    if (!startSet && start <= total + length) {
      range.setStart(node, start - total)
      startSet = true
    }
    if (startSet && end <= total + length) {
      range.setEnd(node, end - total)
      return range
    }
    total += length
  }
  return null
}

// The character offset under a pointer event, for hit-testing highlights.
// caretPositionFromPoint is the standard; Safari ships caretRangeFromPoint.
export function offsetAtPoint(container: Element, x: number, y: number): number | null {
  const doc = document as Document & {
    caretPositionFromPoint?: (x: number, y: number) => { offsetNode: Node; offset: number } | null
  }
  const range = document.createRange()
  const caret = doc.caretPositionFromPoint?.(x, y)
  if (caret) {
    range.setStart(caret.offsetNode, caret.offset)
  } else {
    const legacy = document.caretRangeFromPoint?.(x, y)
    if (!legacy) return null
    range.setStart(legacy.startContainer, legacy.startOffset)
  }
  range.collapse(true)
  if (!container.contains(range.startContainer)) return null
  const probe = document.createRange()
  probe.selectNodeContents(container)
  probe.setEnd(range.startContainer, range.startOffset)
  return probe.toString().length
}

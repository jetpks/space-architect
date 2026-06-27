// Range-annotation painting via the CSS Custom Highlight API: live Ranges are
// registered per message (keyed to their annotation, so one note's passage can
// be singled out) and pooled into document Highlights styled by the
// ::highlight(annotation) / ::highlight(annotation-active) rules in
// application.css. No DOM mutation — React owns every text node in the
// transcript (markdown + syntax highlighting), so wrapping spans around
// matches would be clobbered or crash on the next render. Where the API is
// missing the paint is simply skipped; the note remains fully readable in its
// message's annotation list, quote included.

export type HighlightEntry = { annotationId: number; range: Range }

const entriesByMessage = new Map<number, HighlightEntry[]>()
// The note whose card is hovered in the margin — its ranges paint with the
// stronger annotation-active style instead of the base wash.
let activeAnnotationId: number | null = null

export function highlightsSupported(): boolean {
  return typeof CSS !== 'undefined' && 'highlights' in CSS
}

export function setMessageHighlights(messageId: number, entries: HighlightEntry[]): void {
  if (entries.length > 0) entriesByMessage.set(messageId, entries)
  else entriesByMessage.delete(messageId)
  repaint()
}

export function clearMessageHighlights(messageId: number): void {
  if (!entriesByMessage.delete(messageId)) return
  repaint()
}

export function setActiveAnnotation(annotationId: number | null): void {
  if (annotationId === activeAnnotationId) return
  activeAnnotationId = annotationId
  repaint()
}

// The tentative wash on a selected passage while its note is being composed in
// the margin — the document selection collapses the moment the composer takes
// focus, so this keeps the passage visibly marked until save or cancel. The
// range is kept (even without Highlight support) so the margin can anchor the
// composer card level with the passage, not the whole message.
let draftRange: Range | null = null

export function setDraftHighlight(range: Range | null): void {
  draftRange = range
  if (!highlightsSupported()) return
  if (range) CSS.highlights.set('note-draft', new Highlight(range))
  else CSS.highlights.delete('note-draft')
}

export function getDraftRange(): Range | null {
  return draftRange
}

// The live painted Range for one annotation, if its quote re-anchored — lets
// the margin sit a range note's card level with its passage rather than the
// top of the (possibly very long) message holding it.
export function getAnnotationRange(annotationId: number): Range | null {
  for (const entries of entriesByMessage.values()) {
    for (const entry of entries) {
      if (entry.annotationId === annotationId) return entry.range
    }
  }
  return null
}

function repaint(): void {
  if (!highlightsSupported()) return
  const all = [...entriesByMessage.values()].flat()
  const active = all.filter((e) => e.annotationId === activeAnnotationId)
  const base = active.length > 0 ? all.filter((e) => e.annotationId !== activeAnnotationId) : all
  paint('annotation', base)
  paint('annotation-active', active)
}

function paint(name: string, entries: HighlightEntry[]): void {
  if (entries.length === 0) CSS.highlights.delete(name)
  else CSS.highlights.set(name, new Highlight(...entries.map((e) => e.range)))
}

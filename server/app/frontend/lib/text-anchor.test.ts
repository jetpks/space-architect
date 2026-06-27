import { describe, expect, it } from 'vitest'
import { buildSelector, resolveSelector } from './text-anchor'

describe('buildSelector', () => {
  it('quotes the range with surrounding context', () => {
    const text = 'The quick brown fox jumps over the lazy dog'
    const sel = buildSelector(text, 10, 19)
    expect(sel).toEqual({
      exact: 'brown fox',
      prefix: 'The quick ',
      suffix: ' jumps over the lazy dog',
      position: 10,
    })
  })

  it('clamps context at the text edges', () => {
    const sel = buildSelector('abcdef', 0, 3)
    expect(sel.prefix).toBe('')
    expect(sel.exact).toBe('abc')
    expect(sel.suffix).toBe('def')

    const end = buildSelector('abcdef', 3, 6)
    expect(end.suffix).toBe('')
  })
})

describe('resolveSelector', () => {
  const roundTrip = (text: string, start: number, end: number) =>
    resolveSelector(text, buildSelector(text, start, end))

  it('round-trips on the same text', () => {
    const text = 'one two three two one'
    expect(roundTrip(text, 4, 7)).toEqual({ start: 4, end: 7 })
  })

  it('finds a unique quote anywhere', () => {
    const sel = { exact: 'needle', prefix: '', suffix: '', position: 0 }
    expect(resolveSelector('hay needle hay', sel)).toEqual({ start: 4, end: 10 })
  })

  it('disambiguates a repeated quote by prefix', () => {
    const text = 'red apple, green apple'
    const sel = buildSelector(text, 17, 22) // the second "apple"
    expect(resolveSelector(text, sel)).toEqual({ start: 17, end: 22 })
  })

  it('disambiguates a repeated quote by suffix', () => {
    const text = 'apple pie or apple tart'
    const sel = { exact: 'apple', prefix: '', suffix: ' tart', position: 0 }
    expect(resolveSelector(text, sel)).toEqual({ start: 13, end: 18 })
  })

  it('breaks context ties by position', () => {
    const text = 'spam spam spam'
    const sel = { exact: 'spam', prefix: '', suffix: '', position: 9 }
    expect(resolveSelector(text, sel)).toEqual({ start: 10, end: 14 })
  })

  it('survives a stale position when the context still matches', () => {
    // Text grew before the quote (a clamp expanded), so position drifted —
    // the prefix/suffix agreement still picks the right occurrence.
    const original = 'intro. the keyword here. keyword again'
    const sel = buildSelector(original, 11, 18) // first "keyword"
    const grown = `a long preamble inserted above. ${original}`
    expect(resolveSelector(grown, sel)).toEqual({ start: 43, end: 50 })
  })

  it('returns null when the quote is gone', () => {
    const sel = { exact: 'vanished', prefix: '', suffix: '', position: 0 }
    expect(resolveSelector('nothing to see', sel)).toBeNull()
  })

  it('returns null for an empty quote', () => {
    expect(resolveSelector('text', { exact: '', prefix: '', suffix: '', position: 0 })).toBeNull()
  })
})

import Anser from 'anser'
import { Fragment } from 'react'

// Renders ANSI/SGR-colored CLI output as styled React spans (no
// dangerouslySetInnerHTML). anser interprets color/decoration codes and drops
// non-SGR control sequences (cursor moves, progress redraws) on its own.
export default function Ansi({ text }: { text: string }) {
  const entries = Anser.ansiToJson(text, { json: true, remove_empty: true })

  return (
    <>
      {entries.map((e, i) => {
        const style: React.CSSProperties = {}
        if (e.fg) style.color = `rgb(${e.fg})`
        if (e.bg) style.backgroundColor = `rgb(${e.bg})`
        if (e.decorations.includes('bold')) style.fontWeight = 'bold'
        if (e.decorations.includes('dim')) style.opacity = 0.6
        if (e.decorations.includes('italic')) style.fontStyle = 'italic'
        if (e.decorations.includes('underline')) style.textDecoration = 'underline'
        if (e.decorations.includes('strikethrough')) style.textDecoration = 'line-through'

        return Object.keys(style).length > 0 ? (
          <span key={i} style={style}>
            {e.content}
          </span>
        ) : (
          <Fragment key={i}>{e.content}</Fragment>
        )
      })}
    </>
  )
}

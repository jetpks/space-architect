import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import remarkBreaks from 'remark-breaks'

// Renders model prose as Markdown. react-markdown emits React elements (it does
// NOT render raw HTML unless rehype-raw is added), so the no-dangerouslySetInnerHTML
// / XSS posture holds. `prose` styling comes from @tailwindcss/typography.
export default function Markdown({ text }: { text: string }) {
  return (
    <div className="prose prose-sm prose-invert max-w-none break-words leading-snug prose-p:my-1.5 prose-headings:mt-3 prose-headings:mb-1 prose-ul:my-1.5 prose-ol:my-1.5 prose-li:my-0.5 prose-pre:my-2 prose-pre:bg-black/40 prose-pre:border prose-pre:border-border">
      <ReactMarkdown remarkPlugins={[remarkGfm, remarkBreaks]}>{text}</ReactMarkdown>
    </div>
  )
}

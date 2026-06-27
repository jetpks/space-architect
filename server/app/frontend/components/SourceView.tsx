import CodeBlock from '@/components/CodeBlock'
import type { Block, Message as MessageType } from '@/types'

// Raw JSON of a turn's blocks, plus any turns folded into its rendering (tool
// results paired to a tool_use, a slash command's stdout). Showing the folded
// turns here keeps the full source obtainable without a separate toggle.
export default function SourceView({
  blocks,
  folded,
}: {
  blocks: Block[]
  folded?: MessageType[]
}) {
  return (
    <div className="space-y-2">
      <CodeBlock text={JSON.stringify(blocks, null, 2)} language="json" />
      {folded?.map((m) => (
        <div key={m.id} className="space-y-1">
          <div className="text-xs uppercase tracking-wide text-muted-foreground">
            folded-in {m.role} turn
          </div>
          <CodeBlock text={JSON.stringify(m.blocks, null, 2)} language="json" />
        </div>
      ))}
    </div>
  )
}

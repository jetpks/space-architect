import { useContext, useState } from 'react'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/components/ui/collapsible'
import { ExpandClampsContext } from '@/lib/expand-clamps'
import Ansi from '@/components/Ansi'
import Markdown from '@/components/Markdown'
import CodeBlock, {
  CODE_BG,
  COLLAPSE_THRESHOLD,
  codeSurface,
  languageFor,
} from '@/components/CodeBlock'
import { MARKER_STYLE, parseToolAnswers, toolDetail, toolDetailField } from '@/lib/tools'
import type { Marker } from '@/lib/tools'
import type {
  Block as BlockType,
  TextBlock,
  ThinkingBlock,
  ToolResultBlock,
  ToolResultIndex,
  ToolUseBlock,
} from '@/types'

// Claude Code wraps slash-command turns in <command-name>/<command-args> and
// pipes their output through <local-command-stdout>. Detect those envelopes so
// we can render a tidy pill instead of the raw tags. We're strict: the envelope
// must *open the message* (after leading whitespace) and be a genuine matched
// pair. So ordinary prose that merely mentions these tags — this very message
// discussing a `<local-command-stdout>` pair, or a code sample showing one
// mid-text — renders literally, as does content with stray angle brackets (C
// headers like <stddef>). A real command message is the envelope and nothing
// before it.
// Claude Code also emits a <command-message>-led ordering where the display
// name precedes the <command-name> tag — that variant is accepted here too.
// A <command-message>-only block with no <command-name>/<local-command-stdout>
// pair falls through (returns null) so it renders as ordinary text.
function parseCommand(text: string) {
  const trimmed = text.trimStart()
  if (!/^(?:<command-name>|<local-command-stdout>|<command-message>)/.test(trimmed)) return null
  const grab = (tag: string) =>
    trimmed.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`))?.[1]?.trim()
  const name = grab('command-name')
  const args = grab('command-args')
  const stdout = grab('local-command-stdout')
  if (!name && !stdout) return null
  return { name, args, stdout }
}

// <task-notification> envelope — background task completion. Strict: must open
// the message and be a genuine matched pair.
type TaskNotification = {
  summary: string
  status: string
  taskId?: string
  toolUseId?: string
  outputFile?: string
}

function parseTaskNotification(text: string): TaskNotification | null {
  const trimmed = text.trimStart()
  if (!trimmed.startsWith('<task-notification>')) return null
  if (!trimmed.includes('</task-notification>')) return null
  const grab = (tag: string) =>
    trimmed.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`))?.[1]?.trim()
  const status = grab('status') ?? ''
  const summary = grab('summary') ?? status
  if (!summary) return null
  return {
    summary,
    status,
    taskId: grab('task-id'),
    toolUseId: grab('tool-use-id'),
    outputFile: grab('output-file'),
  }
}

// <local-command-caveat> / <system-reminder> — harness boilerplate injected
// into turns; never human/agent content. Strict: must open the message and be a
// genuine matched pair.
type Boilerplate = { label: string; body: string }

function parseBoilerplate(text: string): Boilerplate | null {
  const trimmed = text.trimStart()
  if (
    trimmed.startsWith('<local-command-caveat>') &&
    trimmed.includes('</local-command-caveat>')
  ) {
    const body =
      trimmed.match(/<local-command-caveat>([\s\S]*?)<\/local-command-caveat>/)?.[1]?.trim() ?? ''
    return { label: 'caveat', body }
  }
  if (trimmed.startsWith('<system-reminder>') && trimmed.includes('</system-reminder>')) {
    const body =
      trimmed.match(/<system-reminder>([\s\S]*?)<\/system-reminder>/)?.[1]?.trim() ?? ''
    return { label: 'system reminder', body }
  }
  return null
}

// Shared line-clamp state for long blocks: when `text` runs past `threshold`
// lines, render only the first chunk until the reader expands. Returns the text
// to show, the toggle state, and the line count so callers can word the toggle.
// Starts expanded when the surrounding message has range notes — a highlighted
// passage must not load hidden behind the clamp.
function useLineClamp(text: string, threshold: number) {
  const [expanded, setExpanded] = useState(useContext(ExpandClampsContext))
  const lines = text.split('\n')
  const truncatable = lines.length > threshold
  const shown = truncatable && !expanded ? lines.slice(0, threshold).join('\n') : text
  return { shown, count: lines.length, truncatable, expanded, toggle: () => setExpanded((e) => !e) }
}

// Monospace output block (ANSI-colorized). Shows in full when short; for output
// longer than COLLAPSE_THRESHOLD lines, shows the first chunk with a toggle to
// expand/collapse the rest.
function OutputBlock({ text, tone }: { text: string; tone?: 'error' }) {
  const { shown, count, truncatable, expanded, toggle } = useLineClamp(text, COLLAPSE_THRESHOLD)

  return (
    <div className="text-sm">
      <pre
        className="overflow-x-auto"
        style={{
          ...codeSurface,
          background: CODE_BG,
          borderColor: tone === 'error' ? 'rgb(244 63 94 / 0.6)' : undefined,
        }}
      >
        <code>
          <Ansi text={shown} />
        </code>
      </pre>
      {truncatable && (
        <button onClick={toggle} className="mt-1 text-muted-foreground hover:text-foreground">
          {expanded ? 'Collapse' : `Show all ${count} lines`}
        </button>
      )}
    </div>
  )
}

// Prose (a user prompt or the agent's terminal message) shows its first chunk and
// tucks the rest behind a "show more" toggle once it runs past this many lines —
// the same move OutputBlock makes for long tool output, keeping the unified view
// compact when a prompt or summary is long. The count tells you how much is hidden
// before you commit to expanding. (Cutting markdown at a line boundary can leave a
// fence open in the *preview*; acceptable — the full text is one click away, and
// this mirrors the line-based tool cut.)
const PROSE_THRESHOLD = 10

function CollapsibleText({ text }: { text: string }) {
  const { shown, count, truncatable, expanded, toggle } = useLineClamp(text, PROSE_THRESHOLD)

  return (
    <div className="leading-snug">
      <Markdown text={shown} />
      {truncatable && (
        <button
          onClick={toggle}
          className="mt-1 text-sm text-muted-foreground hover:text-foreground"
        >
          {expanded ? 'Show less' : `Show ${count - PROSE_THRESHOLD} more lines`}
        </button>
      )}
    </div>
  )
}

function CommandBlock({ name, args, stdout }: { name?: string; args?: string; stdout?: string }) {
  return (
    <div className="space-y-1">
      {name && (
        <span className="inline-flex items-center gap-1 rounded-md border border-border bg-muted/60 px-2 py-0.5 font-mono text-sm text-primary">
          ⌘ {name}
          {args && <span className="text-muted-foreground">{args}</span>}
        </span>
      )}
      {stdout && <OutputBlock text={stdout} />}
    </div>
  )
}

// Status pill for a completed/failed/in-flight background task. The summary
// line is clickable — it toggles the detail fields (task-id, tool-use-id,
// output-file) collapsed by default, matching the `thinking` Collapsible pattern.
function TaskNotificationBlock({ notification }: { notification: TaskNotification }) {
  const glyph =
    notification.status === 'completed'
      ? '✓'
      : /error|failed/.test(notification.status)
        ? '✗'
        : '•'
  const fields: [string, string][] = []
  if (notification.taskId) fields.push(['task-id', notification.taskId])
  if (notification.toolUseId) fields.push(['tool-use-id', notification.toolUseId])
  if (notification.outputFile) fields.push(['output-file', notification.outputFile])

  return (
    <Collapsible className="text-sm">
      <div className="flex items-center gap-1">
        <span className="font-mono text-muted-foreground">{glyph}</span>
        <CollapsibleTrigger className="text-left text-muted-foreground hover:text-foreground">
          {notification.summary}
        </CollapsibleTrigger>
      </div>
      {fields.length > 0 && (
        <CollapsibleContent>
          <div className="mt-1 space-y-0.5 font-mono text-xs text-muted-foreground">
            {fields.map(([key, value]) => (
              <div key={key}>
                <span className="opacity-60">{key}</span> {value}
              </div>
            ))}
          </div>
        </CollapsibleContent>
      )}
    </Collapsible>
  )
}

// Collapsed marker for harness boilerplate (local-command-caveat /
// system-reminder). Mirrors the `thinking` Collapsible: small italic muted
// trigger, inner text revealed on expand.
function BoilerplateBlock({ label, body }: Boilerplate) {
  return (
    <Collapsible className="text-sm italic text-muted-foreground">
      <CollapsibleTrigger className="hover:text-foreground">{label}</CollapsibleTrigger>
      <CollapsibleContent>
        <div className="mt-1 whitespace-pre-wrap">{body}</div>
      </CollapsibleContent>
    </Collapsible>
  )
}

function toolResultText(content: ToolResultBlock['content']): string {
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    return content.map((part) => (typeof part === 'string' ? part : (part.text ?? ''))).join('\n')
  }
  return String(content ?? '')
}

function ToolResultView({ block }: { block: ToolResultBlock }) {
  return (
    <OutputBlock text={toolResultText(block.content)} tone={block.is_error ? 'error' : undefined} />
  )
}

// "→ Tool  detail" heading shared by every tool-call renderer. A marked tool (a
// decision / memory write / commit) swaps the → for the marker's glyph and tints
// the name its marker color, so the beat reads the same opened as it did in the
// collapsed gist line; the detail stays muted either way.
function ToolHeader({
  name,
  detail,
  marker,
}: {
  name: string
  detail?: React.ReactNode
  marker?: Marker
}) {
  const style = marker ? MARKER_STYLE[marker] : null
  return (
    <div className="font-mono text-sm break-all">
      <span className={style ? style.text : 'text-primary'}>
        {style ? style.glyph : '→'} {name}
      </span>
      {detail != null && <span className="text-muted-foreground"> {detail}</span>}
    </div>
  )
}

// One field of a tool's input, rendered by shape: short scalars sit inline next
// to the key; longer prose (a prompt, a plan) renders as Markdown; anything
// structured falls to a small JSON block. Keeps unmodeled tools readable.
function ToolField({ name, value }: { name: string; value: unknown }) {
  const inline =
    typeof value === 'number' ||
    typeof value === 'boolean' ||
    (typeof value === 'string' && !value.includes('\n') && value.length <= 80)

  if (inline) {
    return (
      <div className="text-sm">
        <span className="font-mono text-xs text-muted-foreground">{name}</span>{' '}
        <span className="break-all">{String(value)}</span>
      </div>
    )
  }

  return (
    <div>
      <div className="font-mono text-xs text-muted-foreground">{name}</div>
      <div className="mt-1 min-w-0">
        {typeof value === 'string' ? (
          <Markdown text={value} />
        ) : (
          <CodeBlock
            text={JSON.stringify(value, null, 2)}
            language="json"
            showLineNumbers={false}
          />
        )}
      </div>
    </div>
  )
}

// Generic rendered view of a tool's input for tools without a bespoke renderer:
// a field list (skipping the field already shown in the header) instead of a raw
// JSON dump. Renders nothing when there's nothing left to show.
function ToolInput({ input, omit }: { input: Record<string, unknown>; omit?: string }) {
  const fields = Object.entries(input).filter(
    ([key, value]) => key !== omit && value != null && value !== '',
  )
  if (fields.length === 0) return null
  return (
    <div className="space-y-2">
      {fields.map(([key, value]) => (
        <ToolField key={key} name={key} value={value} />
      ))}
    </div>
  )
}

// File contents: syntax-highlighted when we recognize the type, otherwise the
// plain expandable monospace preview. Shared by Read results and Write input.
function FileContents({ path, text }: { path: string; text: string }) {
  const language = languageFor(path)
  return language ? <CodeBlock text={text} language={language} /> : <OutputBlock text={text} />
}

// Render an Edit as a diff: the replaced text as removed lines, the replacement
// as added lines. Prism's `diff` grammar colors the -/+ prefixes.
function toDiff(oldString: string, newString: string): string {
  const prefix = (text: string, sign: string) =>
    text.length
      ? text
          .split('\n')
          .map((line) => sign + line)
          .join('\n')
      : ''
  return [prefix(oldString, '-'), prefix(newString, '+')].filter(Boolean).join('\n')
}

type Question = {
  id?: string
  header?: string
  question?: string
  multiSelect?: boolean
  options?: { label?: string; description?: string }[]
}

// The user's choice (one option's label, or free text for "Other") is parsed from
// the folded-in result and passed as `answers` keyed by question text. The chosen
// option lights up emerald — the same accent AskUserQuestion gets as a decision
// beat — and a custom "Other" answer (matching no option) shows as its own line so
// it isn't lost once the raw result string is suppressed.
function AskUserQuestionCall({
  name,
  questions,
  answers = {},
  marker,
}: {
  name: string
  questions: Question[]
  answers?: Record<string, string>
  marker?: Marker
}) {
  return (
    <>
      <ToolHeader name={name} marker={marker} />
      {questions.map((q, i) => {
        const answer = q.question ? answers[q.question] : undefined
        const options = q.options ?? []
        const matched = !!answer && options.some((o) => o.label === answer)
        return (
          <div key={i} className="rounded-md border border-border bg-muted/30 p-3">
            {q.header && (
              <div className="text-xs uppercase tracking-wide text-muted-foreground">
                {q.header}
                {q.multiSelect && ' · multi-select'}
              </div>
            )}
            {q.question && <div className="mt-1 font-medium">{q.question}</div>}
            <ul className="mt-2 space-y-1">
              {options.map((o, j) => {
                const selected = o.label === answer
                return (
                  <li
                    key={j}
                    className={`rounded px-2 py-1 text-sm ${selected ? 'bg-accent/10' : ''}`}
                  >
                    <span
                      className={`font-medium ${selected ? 'text-accent-foreground' : 'text-primary'}`}
                    >
                      {selected && '✓ '}
                      {o.label}
                    </span>
                    {o.description && (
                      <span className="text-muted-foreground"> — {o.description}</span>
                    )}
                  </li>
                )
              })}
            </ul>
            {answer && !matched && (
              <div className="mt-2 text-sm font-medium text-accent-foreground">✓ {answer}</div>
            )}
          </div>
        )
      })}
    </>
  )
}

// Codex's plan checklist: each step with a status glyph — done steps recede,
// the in-progress step carries the accent.
function UpdatePlanCall({
  plan,
  marker,
}: {
  plan: { step?: string; status?: string }[]
  marker?: Marker
}) {
  const glyph = (status?: string) =>
    status === 'completed' ? '✓' : status === 'in_progress' ? '▸' : '○'
  return (
    <>
      <ToolHeader name="update_plan" marker={marker} />
      <ul className="space-y-0.5 text-sm">
        {plan.map((p, i) => (
          <li
            key={i}
            className={
              p.status === 'completed'
                ? 'text-muted-foreground'
                : p.status === 'in_progress'
                  ? 'text-primary'
                  : undefined
            }
          >
            <span className="font-mono">{glyph(p.status)}</span> {p.step}
          </li>
        ))}
      </ul>
    </>
  )
}

// The call portion of a tool_use (header + arguments), rendered per the tool's
// schema. Tools we don't model fall back to pretty-printed JSON. Schemas are
// assumed forward-compatible (arrays may grow, fields may be added).
function toolCallBody(
  b: ToolUseBlock,
  input: Record<string, unknown>,
  marker?: Marker,
): React.ReactNode {
  switch (b.name) {
    case 'Bash':
    case 'bash':
      if (typeof input.command === 'string') {
        return (
          <>
            <ToolHeader name={b.name} detail={toolDetail(input)} marker={marker} />
            <CodeBlock text={input.command} language="bash" showLineNumbers={false} />
          </>
        )
      }
      break
    case 'exec_command':
      // Codex's shell tool: the command lives in `cmd`. No detail in the header —
      // unlike Bash there's no description field, and the command itself renders
      // right below.
      if (typeof input.cmd === 'string') {
        return (
          <>
            <ToolHeader name="exec_command" marker={marker} />
            <CodeBlock text={input.cmd} language="bash" showLineNumbers={false} />
          </>
        )
      }
      break
    case 'apply_patch':
      // Codex's file editor: one envelope of `*** Update File:` hunks with -/+
      // lines, already diff-shaped — Prism's diff grammar colors it directly.
      if (typeof input.patch === 'string') {
        return (
          <>
            <ToolHeader name="apply_patch" detail={toolDetail(input)} marker={marker} />
            <CodeBlock text={input.patch} language="diff" showLineNumbers={false} />
          </>
        )
      }
      break
    case 'update_plan':
      if (Array.isArray(input.plan)) {
        return (
          <UpdatePlanCall
            plan={input.plan as { step?: string; status?: string }[]}
            marker={marker}
          />
        )
      }
      break
    case 'Write':
    case 'write':
      if (typeof input.file_path === 'string' && typeof input.content === 'string') {
        return (
          <>
            <ToolHeader name={b.name} detail={toolDetail(input)} marker={marker} />
            <FileContents path={input.file_path} text={input.content} />
          </>
        )
      }
      break
    case 'Edit':
    case 'edit':
      if (typeof input.file_path === 'string') {
        const detail = input.replace_all
          ? `${toolDetail(input)} (all occurrences)`
          : toolDetail(input)
        return (
          <>
            <ToolHeader name={b.name} detail={detail} marker={marker} />
            <CodeBlock
              text={toDiff(String(input.old_string ?? ''), String(input.new_string ?? ''))}
              language="diff"
              showLineNumbers={false}
            />
          </>
        )
      }
      break
  }

  return (
    <>
      <ToolHeader name={b.name} detail={toolDetail(input)} marker={marker} />
      <ToolInput input={input} omit={toolDetailField(input)} />
    </>
  )
}

export default function Block({
  block,
  toolResults,
  commandStdout,
  marker,
}: {
  block: BlockType
  toolResults?: ToolResultIndex
  // stdout from the *following* turn, when this block is a slash-command (the
  // command and its output are separate adjacent messages — paired in Show).
  commandStdout?: string
  // When this block's message is a marked beat (decision/memory/commit), its tool
  // header swaps the → for the marker glyph and tints the name. Threaded from Turn.
  marker?: Marker
}) {
  switch (block.type) {
    case 'text': {
      const text = (block as TextBlock).text ?? ''
      // Codex records a user interrupt as a <turn_aborted> envelope around fixed
      // boilerplate; Markdown would mangle the unknown tag, so render the short
      // marker Claude's plain-text interrupt naturally reads as.
      if (text.trimStart().startsWith('<turn_aborted>')) {
        return <div className="text-sm italic text-muted-foreground">[interrupted by user]</div>
      }
      const command = parseCommand(text)
      if (command) return <CommandBlock {...command} stdout={command.stdout ?? commandStdout} />
      const notification = parseTaskNotification(text)
      if (notification) return <TaskNotificationBlock notification={notification} />
      const boilerplate = parseBoilerplate(text)
      if (boilerplate) return <BoilerplateBlock {...boilerplate} />
      return <CollapsibleText text={text} />
    }

    // Reasoning that exists only as ciphertext. Filtered out of the transcript
    // body in Show; this is the fallback for the rare case one is kept, e.g.
    // because it was annotated — never expose the raw data through the default
    // renderer.
    case 'redacted_thinking':
      return <div className="text-sm italic text-muted-foreground">thinking (redacted)</div>

    case 'thinking': {
      const thinking = (block as ThinkingBlock).thinking ?? ''
      // Interleaved-thinking noise: a thinking block with no text. Show a
      // marker so the turn doesn't look blank (same rare annotated-and-kept
      // fallback as above).
      if (!thinking) {
        return <div className="text-sm italic text-muted-foreground">thinking (redacted)</div>
      }
      return (
        <Collapsible className="text-sm italic text-muted-foreground">
          <CollapsibleTrigger className="hover:text-foreground">thinking</CollapsibleTrigger>
          <CollapsibleContent>
            <div className="mt-1">
              <Markdown text={thinking} />
            </div>
          </CollapsibleContent>
        </Collapsible>
      )
    }

    case 'tool_use': {
      const b = block as ToolUseBlock
      const input = (b.input ?? {}) as Record<string, unknown>
      // The result for this call lands in a later turn; render it inline so the
      // call and its output read as one coupled unit.
      const result = b.id ? toolResults?.byUseId[b.id] : undefined

      // Read is special: the file contents ARE the result, so render them in
      // place of a generic result block (highlighted when the type is known).
      // Pi names the tool lowercase `read`; Claude uses `Read`.
      if ((b.name === 'Read' || b.name === 'read') && typeof input.file_path === 'string') {
        return (
          <div className="space-y-1">
            <ToolHeader name={b.name} detail={toolDetail(input)} marker={marker} />
            {result &&
              (result.is_error ? (
                <ToolResultView block={result} />
              ) : (
                <FileContents path={input.file_path} text={toolResultText(result.content)} />
              ))}
          </div>
        )
      }

      // Question tools (Claude's AskUserQuestion, codex's request_user_input) fold
      // their answer into the result; render the choice on the question cards
      // (emerald highlight) instead of dumping the raw result string.
      if (
        (b.name === 'AskUserQuestion' || b.name === 'request_user_input') &&
        Array.isArray(input.questions)
      ) {
        const questions = input.questions as Question[]
        const answers = result ? parseToolAnswers(toolResultText(result.content), questions) : {}
        return (
          <div className="space-y-1">
            <AskUserQuestionCall
              name={b.name}
              questions={questions}
              answers={answers}
              marker={marker}
            />
          </div>
        )
      }

      return (
        <div className="space-y-1">
          {toolCallBody(b, input, marker)}
          {result && <ToolResultView block={result} />}
        </div>
      )
    }

    case 'tool_result': {
      const b = block as ToolResultBlock
      // Already shown inline under its tool_use — suppress the standalone copy.
      if (b.tool_use_id && toolResults?.useIds.has(b.tool_use_id)) return null
      return <ToolResultView block={b} />
    }

    default:
      return (
        <Collapsible className="text-sm">
          <CollapsibleTrigger className="text-muted-foreground hover:text-foreground">
            {block.type}
          </CollapsibleTrigger>
          <CollapsibleContent>
            <CodeBlock
              text={JSON.stringify(block, null, 2)}
              language="json"
              showLineNumbers={false}
            />
          </CollapsibleContent>
        </Collapsible>
      )
  }
}

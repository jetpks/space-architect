import type { Message, TextBlock, ThinkingBlock, ToolUseBlock } from '@/types'

// A one-line summary of a message: its text blocks (falling back to thinking),
// with slash-command envelopes tidied and whitespace collapsed, clipped to `max`
// chars. Returns '' when there's nothing readable (e.g. a tool-only message).
// Shared by the Turn gist stack and the TOC rail.
export function gist(message: Message, max = 128): string {
  let raw = message.blocks
    .filter((b) => b.type === 'text')
    .map((b) => (b as TextBlock).text ?? '')
    .join(' ')
    .trim()
  if (!raw) {
    raw = message.blocks
      .filter((b) => b.type === 'thinking')
      .map((b) => (b as ThinkingBlock).thinking ?? '')
      .join(' ')
      .trim()
  }
  const text = raw
    .replace(/<command-name>([\s\S]*?)<\/command-name>/g, '⌘ $1')
    .replace(/<command-args>([\s\S]*?)<\/command-args>/g, ' $1')
    .replace(/<command-message>[\s\S]*?<\/command-message>/g, ' ')
    .replace(/<local-command-[a-z]+>[\s\S]*?<\/local-command-[a-z]+>/g, ' ')
    .replace(/<turn_aborted>[\s\S]*?(?:<\/turn_aborted>|$)/g, ' interrupted ')
    .replace(/\s+/g, ' ')
    .trim()
  return text.length > max ? `${text.slice(0, max).trimEnd()}…` : text
}

// Ordered preference for the human-readable detail shown after a tool's name.
// Shared by the expanded ToolHeader and the collapsed gist row so the two stay
// in sync. First field present as a non-empty string wins. (Field set derived
// from the tools actually seen in transcripts — extend as new ones appear.)
const DETAIL_FIELDS = ['subject', 'description', 'file_path', 'cmd', 'query', 'url', 'status']

// Tools that mark a human-in-the-loop decision point — the user is asked to
// choose (AskUserQuestion / codex's request_user_input) or to approve a plan
// (ExitPlanMode). These are the significant beats of a conversation: tinted
// emerald, rendered as phase dividers inside a turn, and listed as jump targets
// in the TOC. They are NOT turn boundaries — see memory
// chat-share-decisions-not-boundaries for why.
const DECISION_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode', 'request_user_input'])

function isDecisionMessage(blocks: { type: string; [key: string]: unknown }[]): boolean {
  return blocks.some(
    (b) => b.type === 'tool_use' && typeof b.name === 'string' && DECISION_TOOLS.has(b.name),
  )
}

// Writes/edits to the agent's memory files — file-writing tools whose path is a
// `/memory/` file *outside* the project root (memories live under ~/.claude, not
// the repo). The outside-root test disambiguates from a project's own /memory/
// dir; confirmed against conversation 6. Another significant beat, like decisions.
const MEMORY_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit'])

function basename(path: string): string {
  const clean = path.replace(/\/+$/, '')
  const slash = clean.lastIndexOf('/')
  return slash >= 0 ? clean.slice(slash + 1) : clean
}

// The memory file path a block writes to, or null if it isn't a memory write.
function memoryPath(
  block: { type: string; [key: string]: unknown },
  projectRoot?: string | null,
): string | null {
  if (block.type !== 'tool_use' || typeof block.name !== 'string') return null
  if (!MEMORY_TOOLS.has(block.name)) return null
  const input = (block.input ?? {}) as Record<string, unknown>
  const path =
    typeof input.file_path === 'string'
      ? input.file_path
      : typeof input.notebook_path === 'string'
        ? input.notebook_path
        : null
  if (!path || !/\/memory\//i.test(path)) return null
  if (projectRoot && path.startsWith(projectRoot)) return null
  return path
}

function isMemoryMessage(
  blocks: { type: string; [key: string]: unknown }[],
  projectRoot?: string | null,
): boolean {
  return blocks.some((b) => memoryPath(b, projectRoot) !== null)
}

// "memory: {filename}" — the file the write touched.
function memoryLabel(message: Message, projectRoot?: string | null): string {
  for (const b of message.blocks) {
    const path = memoryPath(b, projectRoot)
    if (path) return `memory: ${basename(path)}`
  }
  return 'memory'
}

// Git commits — a shell call (Claude's `Bash`, codex's `exec_command`) running
// `git commit`. They're commitments, the points a turn made its work durable,
// so they're a significant beat too.
const SHELL_TOOLS: Record<string, string> = { Bash: 'command', exec_command: 'cmd' }

function commitCommand(block: { type: string; [key: string]: unknown }): string | null {
  if (block.type !== 'tool_use' || typeof block.name !== 'string') return null
  const field = SHELL_TOOLS[block.name]
  if (!field) return null
  const cmd = (block.input as Record<string, unknown> | undefined)?.[field]
  // Allow git's global options before the subcommand — `git -C path commit`,
  // `git -c user.name=… commit` — each a `-flag` optionally trailed by a non-flag
  // value. Without this we missed every commit run from another directory.
  if (typeof cmd !== 'string' || !/\bgit(?:\s+-\S+(?:\s+[^-\s]\S*)?)*\s+commit\b/.test(cmd))
    return null
  return cmd
}

function isCommitMessage(blocks: { type: string; [key: string]: unknown }[]): boolean {
  return blocks.some((b) => commitCommand(b) !== null)
}

// "commit: {subject}" — the subject is the message's first line, pulled from a
// plain -m, or from a heredoc body (`-F - <<'EOF' …` or `-m "$(cat <<'EOF' …)"`).
// Falls back to a bare "commit" when there's no message to read (e.g. editor commit).
function commitLabel(message: Message): string {
  for (const b of message.blocks) {
    const cmd = commitCommand(b)
    if (!cmd) continue
    const subject = commitSubject(cmd)
    if (subject) return `commit: ${clipEnd(subject, 48)}`
  }
  return 'commit'
}

function commitSubject(cmd: string): string | null {
  // A plain -m "message" — but NOT a $(…) / heredoc wrapper, which is shell
  // plumbing, not the subject (that case falls through to the heredoc read below).
  const flag = cmd.match(/-m\s+(["'])([\s\S]*?)\1/)
  if (flag && !/\$\(|<</.test(flag[2])) {
    const line = flag[2].split('\n')[0].trim()
    if (line) return line
  }
  // A heredoc body (`<<'EOF' … EOF`): the subject is its first non-empty line.
  const here = cmd.match(/<<-?\s*['"]?(\w+)['"]?\r?\n([\s\S]*?)\r?\n\s*\1\b/)
  if (here) {
    const line = here[2]
      .split('\n')
      .map((l) => l.trim())
      .find((l) => l.length > 0)
    if (line) return line
  }
  return null
}

// The significant-beat markers we surface (emerald decisions, orange memory
// writes). Each is tinted in the gist stack, rendered as a marked action row,
// and listed as a TOC jump target. Class literals live here so Tailwind sees
// them and Turn/TurnToc stay in sync.
export type Marker = 'decision' | 'memory' | 'commit'

// text/textHover/subtle tint labels; seam is the trailing rule's bg on a marker
// row; rule is the *border* color of a marked tool's fold bracket (so the bracket
// reads in the marker's color, not neutral).
export const MARKER_STYLE: Record<
  Marker,
  { glyph: string; text: string; textHover: string; subtle: string; seam: string; rule: string }
> = {
  decision: {
    glyph: '⬥',
    text: 'text-emerald-400',
    textHover: 'hover:text-emerald-300',
    subtle: 'text-emerald-400/80',
    seam: 'bg-emerald-500/30',
    rule: 'border-emerald-500/40',
  },
  memory: {
    glyph: '✎',
    text: 'text-orange-400',
    textHover: 'hover:text-orange-300',
    subtle: 'text-orange-400/80',
    seam: 'bg-orange-500/30',
    rule: 'border-orange-500/40',
  },
  commit: {
    glyph: '⎇',
    text: 'text-purple-400',
    textHover: 'hover:text-purple-300',
    subtle: 'text-purple-400/80',
    seam: 'bg-purple-500/30',
    rule: 'border-purple-500/40',
  },
}

// The header band that opens each section of a turn — prompt · thought · terminal.
// A tinted strip carrying a bold title + the section's controls, so the sections
// read as titled peers on one neutral surface. Shared by Turn (prompt, thought) and
// Message (a terminal/section message) so the three can't drift; centralized here
// alongside MARKER_STYLE so Tailwind's scan sees the literals.
export const SECTION_HEADER =
  'mb-2 flex items-center gap-2 rounded-md bg-muted/60 px-3 py-1.5 text-xs uppercase tracking-wide text-muted-foreground'

export function messageMarker(message: Message, projectRoot?: string | null): Marker | null {
  if (isDecisionMessage(message.blocks)) return 'decision'
  if (isMemoryMessage(message.blocks, projectRoot)) return 'memory'
  if (isCommitMessage(message.blocks)) return 'commit'
  return null
}

export function markerLabel(message: Message, marker: Marker, projectRoot?: string | null): string {
  switch (marker) {
    case 'decision':
      return decisionLabel(message)
    case 'memory':
      return memoryLabel(message, projectRoot)
    case 'commit':
      return commitLabel(message)
  }
}

// The marked messages within a turn, in document order — for the TOC sub-entries.
export function turnMarkers(
  messages: Message[],
  projectRoot?: string | null,
): { message: Message; marker: Marker }[] {
  return messages.flatMap((message) => {
    const marker = messageMarker(message, projectRoot)
    return marker ? [{ message, marker }] : []
  })
}

// A message that performs an action (calls a tool) vs. one that's pure
// reasoning/narrative. The import stores one block per message, so this cleanly
// separates "thinking/saying" from "doing".
export function isActionMessage(message: Message): boolean {
  return message.blocks.some((b) => b.type === 'tool_use')
}

// The continuation summary Claude Code injects right before a /compact command —
// machinery, not a human prompt (the server already groups it into the /compact
// turn; see Turn.compact_summary?). Detected by the known preamble so the turn
// can fold it behind a disclosure instead of rendering a giant fake message.
const COMPACT_SUMMARY_PREAMBLE =
  'This session is being continued from a previous conversation that ran out of context'
export function isCompactSummary(message: Message): boolean {
  if (message.role !== 'user') return false
  const text = message.blocks
    .filter((b) => b.type === 'text')
    .map((b) => (b as TextBlock).text ?? '')
    .join('\n')
  return text.trimStart().startsWith(COMPACT_SUMMARY_PREAMBLE)
}

// A thinking message with nothing readable in it: redacted_thinking (Codex
// chain-of-thought kept only as ciphertext) or an empty thinking block
// (interleaved-thinking noise — a signature over an empty string). Both are
// hidden from the transcript body; only the former shapes round boundaries,
// and that happens server-side.
export function isEncryptedThinking(message: Message): boolean {
  return (
    message.blocks.length > 0 &&
    message.blocks.every(
      (b) =>
        b.type === 'redacted_thinking' ||
        (b.type === 'thinking' && !((b as ThinkingBlock).thinking ?? '').trim()),
    )
  )
}

// A short phrase naming a decision: "plan approved" for ExitPlanMode, or
// "decision: {topic}" drawn from the first question's header for AskUserQuestion.
function decisionLabel(message: Message): string {
  const tool = message.blocks.find(
    (b) =>
      b.type === 'tool_use' &&
      typeof (b as ToolUseBlock).name === 'string' &&
      DECISION_TOOLS.has((b as ToolUseBlock).name),
  ) as ToolUseBlock | undefined
  if (!tool) return 'decision'
  if (tool.name === 'ExitPlanMode') return 'plan approved'
  const input = (tool.input as Record<string, unknown>) ?? {}
  const questions = Array.isArray(input.questions) ? input.questions : []
  const first = questions[0] as { header?: string; question?: string } | undefined
  const topic = first?.header?.trim() || first?.question?.trim()
  return topic ? `decision: ${clipEnd(topic, 48)}` : 'decision'
}

// AskUserQuestion's tool_result is a flat sentence the tool emits once the user
// answers: `Your questions have been answered: "<question>"="<answer>", … .` Parse
// it back into a {question → answer} map so the rendered question cards can light
// up the chosen option. An answer is an option's label, or free text when the user
// picked "Other". Best-effort — an unrecognized result just yields {} (nothing lit).
export function parseAskUserAnswers(resultText: string): Record<string, string> {
  const answers: Record<string, string> = {}
  const pair = /"([^"]*)"="([^"]*)"/g
  let m: RegExpExecArray | null
  while ((m = pair.exec(resultText)) !== null) answers[m[1]] = m[2]
  return answers
}

// Codex's request_user_input answers come back as JSON keyed by question *id* —
// `{"answers":{"<id>":{"answers":["<label>"]}}}` — but the question cards look
// answers up by question *text*. Map ids back through the questions array
// (codex questions carry an `id`); a non-JSON result falls through to the
// Claude flat-sentence parse, so one entry point serves both shapes.
export function parseToolAnswers(
  resultText: string,
  questions: { id?: string; question?: string }[],
): Record<string, string> {
  try {
    const parsed = JSON.parse(resultText) as { answers?: Record<string, { answers?: string[] }> }
    const byId = parsed?.answers
    if (byId && typeof byId === 'object') {
      const answers: Record<string, string> = {}
      for (const q of questions) {
        const chosen = q.id ? byId[q.id]?.answers : undefined
        if (q.question && chosen?.length) answers[q.question] = chosen.join(', ')
      }
      return answers
    }
  } catch {
    // not JSON — the Claude-style flat sentence
  }
  return parseAskUserAnswers(resultText)
}

// The file paths an apply_patch call touches, read from its envelope's
// `*** Update|Add|Delete File: <path>` lines — the header detail for the call.
export function applyPatchFiles(patch: string): string[] {
  const files: string[] = []
  const line = /^\*\*\* (?:Update|Add|Delete) File: (.+)$/gm
  let m: RegExpExecArray | null
  while ((m = line.exec(patch)) !== null) files.push(m[1].trim())
  return files
}

function detailEntry(
  input: Record<string, unknown> | undefined,
): readonly [string, string] | undefined {
  if (!input) return undefined
  for (const field of DETAIL_FIELDS) {
    const value = input[field]
    if (typeof value === 'string' && value.trim()) return [field, value.trim()] as const
  }
  // apply_patch carries no path field — derive the detail from the patch
  // envelope's File: lines. Reported as file_path so it clips like one.
  if (typeof input.patch === 'string') {
    const files = applyPatchFiles(input.patch)
    if (files.length) {
      const label = files.length > 1 ? `${files[0]} (+${files.length - 1})` : files[0]
      return ['file_path', label] as const
    }
  }
  return undefined
}

export function toolDetail(input: Record<string, unknown> | undefined): string | undefined {
  return detailEntry(input)?.[1]
}

// The input field the header detail was drawn from, so the rendered body can
// skip it instead of repeating it.
export function toolDetailField(input: Record<string, unknown> | undefined): string | undefined {
  return detailEntry(input)?.[0]
}

// Path-like detail fields: the tail (filename / endpoint) carries the meaning,
// so when these are clipped we drop the front, not the end.
const PATH_FIELDS = new Set(['file_path', 'url'])

function clipEnd(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max).trimEnd()}…` : text
}

// Keep the last `max` chars, then snap forward to a path separator so the result
// starts at a clean segment ("…/chat-share/app/models/turn.rb").
function clipFront(text: string, max: number): string {
  if (text.length <= max) return text
  const tail = text.slice(text.length - max)
  const slash = tail.indexOf('/')
  return `…${slash >= 0 ? tail.slice(slash) : tail}`
}

// "→ Name detail" label for a tool call, clipped for compact gist rows — paths
// clipped from the front, everything else from the end.
export function toolLabel(block: ToolUseBlock, max = 128): string {
  const entry = detailEntry(block.input as Record<string, unknown> | undefined)
  if (!entry) return `→ ${block.name}`
  const [field, value] = entry
  const prefix = `→ ${block.name} `
  const budget = Math.max(8, max - prefix.length)
  return prefix + (PATH_FIELDS.has(field) ? clipFront(value, budget) : clipEnd(value, budget))
}

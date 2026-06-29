import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { Annotation, Message as MessageType, Round as RoundType, ToolResultIndex } from '@/types'
import { indexAnnotations } from '@/lib/annotation-index'

vi.mock('@inertiajs/react', () => ({
  useForm: () => ({ data: {}, post: vi.fn(), reset: vi.fn() }),
  usePage: () => ({ props: { current_user: null, flash: {} } }),
  router: { delete: vi.fn() },
}))

vi.mock('@/components/UserChip', () => ({
  default: ({ name }: { name: string }) => <span>{name}</span>,
}))

vi.mock('@/components/Message', () => ({
  default: ({ message, marker }: { message: MessageType; marker?: string }) => (
    <div data-testid={`message-${message.id}`} data-marker={marker ?? ''}>
      message-{message.id}
    </div>
  ),
}))

vi.mock('@/components/BarMenu', () => ({
  default: ({ label }: { label: string }) => (
    <div data-testid={`bar-menu-${label.replace(/\s+/g, '-').toLowerCase()}`}>{label}</div>
  ),
}))

vi.mock('@/components/AnnotationSection', () => ({
  default: ({ annotations }: { annotations: Annotation[] }) =>
    annotations.length > 0 ? (
      <div data-testid="annotation-section">{annotations.length} note(s)</div>
    ) : null,
}))

import Turn from '@/components/Turn'

const OWNER = { username: 'tester', name: null, avatar_url: null }
const EMPTY_TOOL_RESULTS: ToolResultIndex = { byUseId: {}, useIds: new Set() }

function makeToolMessage(id: number): MessageType {
  return {
    id,
    role: 'assistant',
    model: null,
    position: id,
    published: false,
    can_publish: false,
    blocks: [{ type: 'tool_use', id: `tu-${id}`, name: 'Bash', input: { command: 'echo hi' } }],
  }
}

// A text (non-action) message — used as the turn's terminal so tool messages
// are not mistakenly peeled off as the terminal by Turn's intermediate logic.
function makeTextMessage(id: number): MessageType {
  return {
    id,
    role: 'assistant',
    model: null,
    position: id,
    published: false,
    can_publish: false,
    blocks: [{ type: 'text', text: 'done.' }],
  }
}

function makeRound(anchorId: number, messages: MessageType[]): RoundType {
  return { anchor_id: anchorId, messages }
}

const BASE_PROPS = {
  anchorId: 1,
  number: 1,
  prompt: null,
  rounds: [] as RoundType[],
  conversationId: 42,
  annotations: new Map<string, Annotation[]>(),
  toolResults: EMPTY_TOOL_RESULTS,
  commandStdout: {} as Record<number, string>,
  folded: {} as Record<number, MessageType[]>,
  reveal: null,
  color: 'transparent',
  projectRoot: null,
  owner: OWNER,
}

// Four tools — exceeds the old AUTO_EXPAND_ACTIONS threshold of 3.
// A trailing text message (id=999) acts as the terminal so all 4 tools
// remain as intermediate action rows and each gets an anchor id.
const tools = [101, 102, 103, 104].map(makeToolMessage)
const round = makeRound(10, [...tools, makeTextMessage(999)])

describe('Turn — flat tool rendering inside open round', () => {
  // The collapsed round renders a chevron button + a gist button, both with
  // aria-label "Expand round". The chevron (first in DOM) is the proper toggle.
  function openRound() {
    fireEvent.click(screen.getAllByRole('button', { name: /expand round/i })[0])
  }

  it('tools are NOT visible while round is collapsed', () => {
    render(<Turn {...BASE_PROPS} rounds={[round]} />)
    expect(screen.queryByTestId('message-101')).toBeNull()
  })

  it('all tools (including >3) are visible inline after opening round — no per-tool expand needed', () => {
    render(<Turn {...BASE_PROPS} rounds={[round]} />)
    openRound()
    for (const t of tools) {
      expect(screen.getByTestId(`message-${t.id}`)).not.toBeNull()
    }
  })

  it('no per-tool BarMenu ("Tool actions") exists when round is open (AC-3)', () => {
    render(<Turn {...BASE_PROPS} rounds={[round]} />)
    openRound()
    expect(screen.queryByTestId('bar-menu-tool-actions')).toBeNull()
  })

  it('no per-tool expand/collapse button exists when round is open (AC-3)', () => {
    render(<Turn {...BASE_PROPS} rounds={[round]} />)
    openRound()
    // Only the round-level "Collapse round" button should exist; no per-tool ones.
    expect(screen.queryByRole('button', { name: 'Expand' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Collapse' })).toBeNull()
  })

  it('no FOLD_FRAME bracket (rounded-tl-md) on inline tool wrapper (AC-3)', () => {
    const { container } = render(<Turn {...BASE_PROPS} rounds={[round]} />)
    openRound()
    // Only the summary fold (not present here) uses FOLD_FRAME; tool wrappers must not.
    expect(container.querySelectorAll('[class*="rounded-tl-md"]')).toHaveLength(0)
  })

  it('round chevron toggles round open and closed (AC-4a)', () => {
    render(<Turn {...BASE_PROPS} rounds={[round]} />)
    expect(screen.queryByTestId('message-101')).toBeNull()

    openRound()
    expect(screen.getByTestId('message-101')).not.toBeNull()

    // Once open, there is exactly one "Collapse round" button (the chevron).
    fireEvent.click(screen.getByRole('button', { name: /collapse round/i }))
    expect(screen.queryByTestId('message-101')).toBeNull()
  })

  it('each inline tool carries anchor id (tool-${id}) and scroll-mt-20 (AC-4b)', () => {
    const { container } = render(<Turn {...BASE_PROPS} rounds={[round]} />)
    openRound()
    for (const t of tools) {
      const el = container.querySelector(`#tool-${t.id}`)
      expect(el).not.toBeNull()
      expect(el!.className).toContain('scroll-mt-20')
    }
  })

  it('non-marked tools use tool-${id} anchor (AC-4b)', () => {
    // All four test tools are Bash (non-marked), so anchor must be tool-${id}.
    const { container } = render(<Turn {...BASE_PROPS} rounds={[round]} />)
    openRound()
    for (const t of tools) {
      expect(container.querySelector(`#tool-${t.id}`)).not.toBeNull()
    }
  })

  it('existing tool-targeted annotation displays with its inline tool (AC-4d)', () => {
    const toolNote: Annotation = {
      id: 1,
      body: 'test note',
      author: 'tester',
      author_avatar_url: null,
      can_delete: false,
      target_kind: 'tool',
      anchor_message_id: 101,
      tool_use_id: 'tu-101',
      selector: null,
    }
    const annotations = indexAnnotations([toolNote])
    // A noted tool means its round auto-opens on init (note must be visible on load).
    // The annotation section is therefore visible without any explicit click.
    render(<Turn {...BASE_PROPS} rounds={[round]} annotations={annotations} />)
    expect(screen.getByTestId('annotation-section')).not.toBeNull()
  })

  it('round with two tools renders both inline (structure check)', () => {
    const twoTools = [makeToolMessage(201), makeToolMessage(202)]
    const r = makeRound(20, twoTools)
    render(<Turn {...BASE_PROPS} rounds={[r]} />)
    fireEvent.click(screen.getAllByRole('button', { name: /expand round/i })[0])
    expect(screen.getByTestId('message-201')).not.toBeNull()
    expect(screen.getByTestId('message-202')).not.toBeNull()
  })
})

describe('Turn — open-round width: right cluster hidden when open (I12)', () => {
  function openRound() {
    fireEvent.click(screen.getAllByRole('button', { name: /expand round/i })[0])
  }

  it('tool count text is absent when round is open (AC-3)', () => {
    render(<Turn {...BASE_PROPS} rounds={[round]} />)
    openRound()
    // "4 tools" must not appear anywhere in the open round header
    expect(screen.queryByText(/\d+ tools?/)).toBeNull()
  })

  it('round BarMenu ("Round actions") is absent when round is open (AC-3)', () => {
    render(<Turn {...BASE_PROPS} rounds={[round]} />)
    openRound()
    expect(screen.queryByTestId('bar-menu-round-actions')).toBeNull()
  })

  it('collapsed round still shows tool count (AC-4 invariant)', () => {
    render(<Turn {...BASE_PROPS} rounds={[round]} />)
    // Before opening: count must be visible
    expect(screen.getByText('4 tools')).not.toBeNull()
  })

  it('collapsed round still shows round BarMenu (AC-4 invariant)', () => {
    render(<Turn {...BASE_PROPS} rounds={[round]} />)
    // Before opening: menu must be present
    expect(screen.getByTestId('bar-menu-round-actions')).not.toBeNull()
  })
})

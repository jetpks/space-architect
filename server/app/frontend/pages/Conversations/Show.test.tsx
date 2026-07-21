import { render, screen } from '@testing-library/react'
import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { Conversation } from '@/types'

vi.mock('@inertiajs/react', () => ({
  Head: (_props: { title?: string }) => null,
  Link: ({ href, children }: { href: string; children?: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
  usePage: () => ({ props: { current_user: null, flash: {} } }),
  useForm: () => ({
    data: {} as Record<string, string>,
    setData: () => {},
    post: () => {},
    processing: false,
    errors: {} as Record<string, string>,
  }),
  router: { patch: () => {}, delete: () => {}, post: () => {} },
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

import Show from './Show'

const CONVERSATION: Conversation = {
  id: 5,
  title: 'Fix the frobnicator',
  status: 'complete',
  published: false,
  source: null,
  original_cwd: null,
  git_branch: null,
  agent_version: null,
  can_manage: false,
  can_note: false,
  owner: { username: 'eric', name: null, avatar_url: null },
}

function renderShow(conversation: Conversation) {
  return render(
    <Show conversation={conversation} turns={[]} annotations={[]} shares={null} />,
  )
}

describe('Conversations/Show', () => {
  beforeEach(() => {
    vi.stubGlobal('matchMedia', (query: string) => ({
      matches: false,
      media: query,
      addEventListener: () => {},
      removeEventListener: () => {},
    }))
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('renders a parent link when parent is present', () => {
    const conversation = { ...CONVERSATION, parent: { id: 3, title: 'Parent session' } }
    renderShow(conversation)

    const link = screen.getByText('Parent session').closest('a')
    expect(link).not.toBeNull()
    expect(link).toHaveAttribute('href', '/conversations/3')
  })

  it('falls back to a generic label when the parent has no title', () => {
    const conversation = { ...CONVERSATION, parent: { id: 3, title: null } }
    renderShow(conversation)

    const link = screen.getByText('conversation #3').closest('a')
    expect(link).toHaveAttribute('href', '/conversations/3')
  })

  it('renders one link per child under "Subagent transcripts"', () => {
    const conversation = {
      ...CONVERSATION,
      children: [
        { id: 6, title: 'Subagent one', session_id: 'sess-a' },
        { id: 7, title: null, session_id: 'sess-b' },
      ],
    }
    renderShow(conversation)

    expect(screen.getByText('Subagent transcripts')).not.toBeNull()

    const linkOne = screen.getByText('Subagent one').closest('a')
    expect(linkOne).toHaveAttribute('href', '/conversations/6')

    const linkTwo = screen.getByText('sess-b').closest('a')
    expect(linkTwo).toHaveAttribute('href', '/conversations/7')
  })

  it('renders neither section when parent/children are absent', () => {
    renderShow(CONVERSATION)

    expect(screen.queryByText('Subagent transcripts')).toBeNull()
    expect(screen.queryByText(/^part of/)).toBeNull()
  })

  it('renders neither section when children is empty', () => {
    renderShow({ ...CONVERSATION, parent: null, children: [] })

    expect(screen.queryByText('Subagent transcripts')).toBeNull()
    expect(screen.queryByText(/^part of/)).toBeNull()
  })
})

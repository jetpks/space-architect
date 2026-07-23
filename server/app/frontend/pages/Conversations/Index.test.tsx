import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { ConversationListItem } from '@/types'

vi.mock('@inertiajs/react', () => ({
  Link: ({ href, children }: { href: string; children?: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
  Head: (_props: { title?: string }) => null,
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

import Index from './Index'

const CONVERSATION: ConversationListItem = {
  id: 1,
  title: 'A conversation',
  status: 'active',
  published: false,
  turns_count: 3,
  owned: true,
  shared: false,
}

const NO_PAGINATION = { page: 1, has_more: false }

describe('Conversations/Index', () => {
  it('renders a link to each conversation', () => {
    const { container } = render(<Index conversations={[CONVERSATION]} pagination={NO_PAGINATION} />)
    expect(container.querySelector('a[href="/conversations/1"]')).not.toBeNull()
  })

  it('renders empty state when no conversations', () => {
    const { container } = render(<Index conversations={[]} pagination={NO_PAGINATION} />)
    expect(container.textContent).toContain('No conversations yet')
  })

  it('renders no pagination controls on a lone page', () => {
    const { queryByRole } = render(<Index conversations={[CONVERSATION]} pagination={NO_PAGINATION} />)
    expect(queryByRole('button', { name: 'Next' })).toBeNull()
  })

  it('renders pagination controls from the prop when a further page exists', () => {
    const { getByRole } = render(
      <Index conversations={[CONVERSATION]} pagination={{ page: 1, has_more: true }} />,
    )
    expect(getByRole('button', { name: 'Next' })).not.toBeDisabled()
    expect(getByRole('button', { name: 'Prev' })).toBeDisabled()
  })
})

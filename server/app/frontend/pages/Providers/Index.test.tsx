import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { Provider } from './Index'

const { post } = vi.hoisted(() => ({ post: vi.fn() }))

vi.mock('@inertiajs/react', () => ({
  Link: ({ href, children }: { href: string; children?: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
  Head: (_props: { title?: string }) => null,
  router: { post },
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

import Index from './Index'

const PROVIDER: Provider = {
  id: 1,
  name: 'openrouter',
  base_url: 'https://openrouter.ai/api/v1',
  api_key_ref: 'op://vault/item',
  flavors: ['openai'],
}

describe('Providers/Index', () => {
  it('renders each provider with name, base_url, and flavors', () => {
    const { container } = render(<Index providers={[PROVIDER]} />)
    expect(container.textContent).toContain('openrouter')
    expect(container.textContent).toContain('https://openrouter.ai/api/v1')
    expect(container.textContent).toContain('openai')
  })

  it('renders a key-ref chip when api_key_ref is present', () => {
    const { container } = render(<Index providers={[PROVIDER]} />)
    expect(container.textContent).toContain('op ref')
  })

  it('renders a keyless chip when api_key_ref is absent', () => {
    const { container } = render(
      <Index providers={[{ ...PROVIDER, api_key_ref: null }]} />,
    )
    expect(container.textContent).toContain('keyless')
  })

  it('renders a "New provider" link to /providers/new', () => {
    const { container } = render(<Index providers={[]} />)
    expect(container.querySelector('a[href="/providers/new"]')).not.toBeNull()
  })

  it('renders empty state when no providers', () => {
    const { container } = render(<Index providers={[]} />)
    expect(container.textContent).toContain('No providers yet')
  })

  it('deletes a provider via POST /providers/:id/delete after confirming', () => {
    render(<Index providers={[PROVIDER]} />)
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    expect(post).toHaveBeenCalledWith('/providers/1/delete')
  })
})

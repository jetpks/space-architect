import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { Profile } from '@/types'

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

const PROFILE: Profile = {
  id: 1,
  name: 'pi via gateway',
  harness_type: 'pi',
  spec: {
    harness: {
      type: 'pi',
      model: 'gpt-5',
      backend: { base_url: 'https://gateway.example.com' },
      args: [],
    },
    environment: {
      env: { FOO: 'bar' },
      secrets: [],
      deps: [],
      npm: ['typescript'],
      files: [{ path: '/workspace/f.txt', content_b64: 'aGk=' }],
      permissions: { network: false, mounts: [] },
    },
  },
}

describe('Profiles/Index', () => {
  it('renders each profile with name, harness type, and model', () => {
    const { container } = render(<Index profiles={[PROFILE]} />)
    expect(container.textContent).toContain('pi via gateway')
    expect(container.textContent).toContain('pi')
    expect(container.textContent).toContain('gpt-5')
  })

  it('renders entry counts for env/npm/files', () => {
    const { container } = render(<Index profiles={[PROFILE]} />)
    expect(container.textContent).toContain('1 env')
    expect(container.textContent).toContain('1 npm')
    expect(container.textContent).toContain('1 files')
  })

  it('renders a "New profile" link to /profiles/new', () => {
    const { container } = render(<Index profiles={[]} />)
    expect(container.querySelector('a[href="/profiles/new"]')).not.toBeNull()
  })

  it('renders empty state when no profiles', () => {
    const { container } = render(<Index profiles={[]} />)
    expect(container.textContent).toContain('No profiles yet')
  })

  it('deletes a profile via POST /profiles/:id/delete after confirming', () => {
    render(<Index profiles={[PROFILE]} />)
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    expect(post).toHaveBeenCalledWith('/profiles/1/delete')
  })
})

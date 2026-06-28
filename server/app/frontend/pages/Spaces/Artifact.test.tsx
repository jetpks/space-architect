import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import Artifact from './Artifact'

vi.mock('@inertiajs/react', () => ({
  Head: (_props: { title?: string }) => null,
  usePage: () => ({ props: { current_user: null, flash: {} } }),
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div data-testid="layout">{children}</div>,
}))

const SPACE = { id: 1, slug: 'test-space', title: 'Test Space' }

const ARTIFACT = {
  id: 42,
  kind: 'brief',
  path: 'architecture/BRIEF.md',
  title: 'The Brief',
  raw: '# Mission\n\nThis is **important** content for the project.',
}

describe('Spaces/Artifact', () => {
  it('renders the artifact title', () => {
    render(<Artifact space={SPACE} artifact={ARTIFACT} />)
    expect(screen.queryByText('The Brief')).not.toBeNull()
  })

  it('renders artifact.raw as markdown (heading and emphasis rendered as text)', () => {
    render(<Artifact space={SPACE} artifact={ARTIFACT} />)
    expect(screen.queryByText('Mission')).not.toBeNull()
    expect(screen.queryByText(/important/)).not.toBeNull()
  })

  it('renders the space title and artifact kind', () => {
    render(<Artifact space={SPACE} artifact={ARTIFACT} />)
    expect(screen.queryByText(/Test Space/)).not.toBeNull()
    expect(screen.queryByText(/brief/)).not.toBeNull()
  })

  it('renders the artifact path', () => {
    render(<Artifact space={SPACE} artifact={ARTIFACT} />)
    expect(screen.queryByText('architecture/BRIEF.md')).not.toBeNull()
  })
})

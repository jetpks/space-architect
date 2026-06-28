import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { SpaceRunDetail, Turn as TurnType } from '@/types'

vi.mock('@inertiajs/react', () => ({
  Head: (_props: { title?: string }) => null,
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
  default: ({ children }: { children?: ReactNode }) => <div data-testid="layout">{children}</div>,
}))

// BarMenu is Radix UI-backed; mock it to avoid portal/pointer-events API issues in jsdom.
vi.mock('@/components/BarMenu', () => ({
  default: () => null,
}))

import Run from './Run'

const SPACE = { id: 1, slug: 'test', title: 'Test Space' }

const RUN: SpaceRunDetail = {
  id: 1,
  lane: 'frontend',
  role: 'builder',
  status: 'complete',
  producer: 'test-agent',
  session_id: null,
  iteration_id: null,
  conversation_id: null,
}

function makeTurn(promptText: string, responseText: string): TurnType {
  return {
    anchor_id: 1,
    prompt: {
      id: 1,
      role: 'user',
      model: null,
      position: 0,
      published: false,
      blocks: [{ type: 'text', text: promptText }],
      can_publish: false,
    },
    rounds: [
      {
        anchor_id: 2,
        messages: [
          {
            id: 2,
            role: 'assistant',
            model: 'claude-sonnet-4-6',
            position: 1,
            published: false,
            blocks: [{ type: 'text', text: responseText }],
            can_publish: false,
          },
        ],
      },
    ],
  }
}

describe('Spaces/Run', () => {
  it('renders the run header with space title and run info', () => {
    render(<Run space={SPACE} run={RUN} turns={[]} />)
    const header = screen.queryByRole('heading', { level: 1 })
    expect(header).not.toBeNull()
    expect(header!.textContent).toContain('Run #1')
  })

  it('renders turn prompt text content via real Turn/Message/Block components', () => {
    const turn = makeTurn('Hello from test prompt', 'Test response content')
    render(<Run space={SPACE} run={RUN} turns={[turn]} />)
    expect(screen.queryByText('Hello from test prompt')).not.toBeNull()
  })

  it('renders turn response text via real Turn/Message/Block components', () => {
    const turn = makeTurn('User question', 'Assistant answer text')
    render(<Run space={SPACE} run={RUN} turns={[turn]} />)
    expect(screen.queryByText('Assistant answer text')).not.toBeNull()
  })

  it('renders a "no transcript" message when turns is empty', () => {
    render(<Run space={SPACE} run={RUN} turns={[]} />)
    expect(screen.queryByText(/no transcript/i)).not.toBeNull()
  })

  it('renders multiple turns in order', () => {
    const turn1: TurnType = makeTurn('First prompt', 'First response')
    const turn2: TurnType = {
      ...makeTurn('Second prompt', 'Second response'),
      anchor_id: 3,
      prompt: {
        id: 3,
        role: 'user',
        model: null,
        position: 2,
        published: false,
        blocks: [{ type: 'text', text: 'Second prompt' }],
        can_publish: false,
      },
      rounds: [
        {
          anchor_id: 4,
          messages: [
            {
              id: 4,
              role: 'assistant',
              model: null,
              position: 3,
              published: false,
              blocks: [{ type: 'text', text: 'Second response' }],
              can_publish: false,
            },
          ],
        },
      ],
    }
    const { container } = render(<Run space={SPACE} run={RUN} turns={[turn1, turn2]} />)
    const text = container.textContent ?? ''
    expect(text.indexOf('First prompt')).toBeLessThan(text.indexOf('Second prompt'))
  })
})

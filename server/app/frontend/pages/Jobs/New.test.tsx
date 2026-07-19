import { fireEvent, render, screen, within } from '@testing-library/react'
import { describe, expect, it, vi, beforeEach } from 'vitest'

let formData: Record<string, unknown>
let formErrors: Record<string, string>
const setData = vi.fn((key: string, value: unknown) => {
  formData = { ...formData, [key]: value }
})
const post = vi.fn()
const transform = vi.fn()

vi.mock('@inertiajs/react', () => ({
  Head: (_props: { title?: string }) => null,
  useForm: () => ({
    data: formData,
    errors: formErrors,
    processing: false,
    setData,
    transform,
    post,
  }),
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
}))

import New from './New'

beforeEach(() => {
  formData = {
    prompt: '',
    harness_model: '',
    base_url: '',
    api_key_ref: '',
    args: [],
    env: [],
    secrets: [],
    deps: [],
    network: false,
    mounts: [],
  }
  formErrors = {}
  setData.mockClear()
  post.mockClear()
  transform.mockClear()
})

describe('Jobs/New', () => {
  it('renders the v1 spec surface fields', () => {
    render(<New />)
    expect(screen.getByText('Prompt')).not.toBeNull()
    expect(screen.getByText('Model')).not.toBeNull()
    expect(screen.getByText('Backend base URL')).not.toBeNull()
    expect(screen.getByText(/Backend API key ref/)).not.toBeNull()
    expect(screen.getByText('Harness args')).not.toBeNull()
    expect(screen.getByText('Environment variables')).not.toBeNull()
    expect(screen.getByText('Secrets')).not.toBeNull()
    expect(screen.getByText('Dependencies')).not.toBeNull()
    expect(screen.getByText('Allow network access')).not.toBeNull()
    expect(screen.getByText(/Mounts/)).not.toBeNull()
  })

  it('renders per-field errors from form.errors', () => {
    formErrors = { prompt: 'is missing', base_url: 'is not a valid URL' }
    const { container } = render(<New />)
    expect(container.textContent).toContain('is missing')
    expect(container.textContent).toContain('is not a valid URL')
  })

  it('adding a harness arg row appends an empty entry via setData', () => {
    render(<New />)
    const field = screen.getByText('Harness args').closest('div')!
    fireEvent.click(within(field).getByRole('button', { name: 'Add' }))
    expect(setData).toHaveBeenCalledWith('args', [''])
  })

  it('adding an environment variable row appends an empty pair via setData', () => {
    render(<New />)
    const field = screen.getByText('Environment variables').closest('div')!
    fireEvent.click(within(field).getByRole('button', { name: 'Add variable' }))
    expect(setData).toHaveBeenCalledWith('env', [['', '']])
  })

  it('submits by transforming into the nested job spec and posting to /jobs', () => {
    const { container } = render(<New />)
    fireEvent.submit(container.querySelector('form')!)
    expect(transform).toHaveBeenCalled()
    expect(post).toHaveBeenCalledWith('/jobs')

    const transformer = transform.mock.calls[0][0]
    const payload = transformer({
      ...formData,
      prompt: 'do the thing',
      harness_model: 'claude-sonnet-5',
      base_url: 'https://api.example.com',
      api_key_ref: '',
      env: [['FOO', 'bar'], ['', 'skip-me']],
      secrets: [['op://vault/item', 'API_KEY']],
    })
    expect(payload.harness).toEqual({
      type: 'claude',
      model: 'claude-sonnet-5',
      backend: { base_url: 'https://api.example.com' },
      args: [],
    })
    expect(payload.prompt).toBe('do the thing')
    expect(payload.environment.env).toEqual({ FOO: 'bar' })
    expect(payload.environment.secrets).toEqual([{ ref: 'op://vault/item', name: 'API_KEY' }])
    expect(payload.environment.permissions).toEqual({ network: false, mounts: [] })
  })
})

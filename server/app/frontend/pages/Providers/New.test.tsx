import { fireEvent, render, screen } from '@testing-library/react'
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
    name: '',
    base_url: '',
    api_key_ref: '',
    flavors: [],
  }
  formErrors = {}
  setData.mockClear()
  post.mockClear()
  transform.mockClear()
})

describe('Providers/New', () => {
  it('renders the provider form fields', () => {
    render(<New />)
    expect(screen.getByText('Name')).not.toBeNull()
    expect(screen.getByText('Base URL')).not.toBeNull()
    expect(screen.getByText('API key ref (optional)')).not.toBeNull()
    expect(screen.getByText('Flavors')).not.toBeNull()
    expect(screen.getByText('openai')).not.toBeNull()
    expect(screen.getByText('anthropic')).not.toBeNull()
  })

  it('renders hygiene copy on the api key field', () => {
    render(<New />)
    expect(screen.getByText(/never keys/)).not.toBeNull()
  })

  it('checking a flavor box appends it via setData', () => {
    render(<New />)
    fireEvent.click(screen.getAllByRole('checkbox')[0])
    expect(setData).toHaveBeenCalledWith('flavors', ['openai'])
  })

  it('submits by transforming into the frozen payload and posting to /providers, with a key ref', () => {
    const { container } = render(<New />)
    fireEvent.submit(container.querySelector('form')!)
    expect(transform).toHaveBeenCalled()
    expect(post).toHaveBeenCalledWith('/providers')

    const transformer = transform.mock.calls[0][0]
    const payload = transformer({
      ...formData,
      name: 'openrouter',
      base_url: 'https://openrouter.ai/api/v1',
      api_key_ref: 'op://vault/item',
      flavors: ['openai', 'anthropic'],
    })
    expect(payload).toEqual({
      name: 'openrouter',
      base_url: 'https://openrouter.ai/api/v1',
      api_key_ref: 'op://vault/item',
      flavors: ['openai', 'anthropic'],
    })
  })

  it('omits api_key_ref entirely when blank', () => {
    const { container } = render(<New />)
    fireEvent.submit(container.querySelector('form')!)

    const transformer = transform.mock.calls[0][0]
    const payload = transformer({
      ...formData,
      name: 'openrouter',
      base_url: 'https://openrouter.ai/api/v1',
      api_key_ref: '',
      flavors: ['openai'],
    })
    expect(payload).toEqual({
      name: 'openrouter',
      base_url: 'https://openrouter.ai/api/v1',
      flavors: ['openai'],
    })
    expect('api_key_ref' in payload).toBe(false)
  })
})

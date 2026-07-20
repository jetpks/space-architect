import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi, beforeEach } from 'vitest'
import type { Provider } from '@/types'

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
    harness_type: 'claude',
    harness_model: '',
    base_url: '',
    api_key_ref: '',
    args: [],
    env: [],
    secrets: [],
    deps: [],
    npm: [],
    files: [],
    network: false,
    mounts: [],
  }
  formErrors = {}
  setData.mockClear()
  post.mockClear()
  transform.mockClear()
})

afterEach(() => {
  vi.unstubAllGlobals()
})

const ANTHROPIC_PROVIDER: Provider = {
  id: 1,
  name: 'anthropic-direct',
  base_url: 'https://api.anthropic.com',
  api_key_ref: 'op://vault/anthropic',
  flavors: ['anthropic'],
}

describe('Profiles/New', () => {
  it('renders the profile form fields', () => {
    render(<New />)
    expect(screen.getByText('Name')).not.toBeNull()
    expect(screen.getByText('Harness type')).not.toBeNull()
    expect(screen.getByText('Model')).not.toBeNull()
    expect(screen.getByText('Backend base URL')).not.toBeNull()
    expect(screen.getByText('npm packages')).not.toBeNull()
    expect(screen.getByText('Files')).not.toBeNull()
  })

  it('renders hygiene copy on the files field', () => {
    render(<New />)
    expect(screen.getByText(/never keys/)).not.toBeNull()
  })

  it('adding a files row appends an empty path/content entry via setData', () => {
    render(<New />)
    const field = screen.getByText('Files').closest('div')!
    fireEvent.click(within(field).getByRole('button', { name: 'Add file' }))
    expect(setData).toHaveBeenCalledWith('files', [{ path: '', content: '' }])
  })

  it('submits by transforming into {name, spec} and posting to /profiles', () => {
    const { container } = render(<New />)
    fireEvent.submit(container.querySelector('form')!)
    expect(transform).toHaveBeenCalled()
    expect(post).toHaveBeenCalledWith('/profiles')

    const transformer = transform.mock.calls[0][0]
    const payload = transformer({
      ...formData,
      name: 'pi via gateway',
      harness_type: 'pi',
      harness_model: 'gpt-5',
      base_url: 'https://gateway.example.com',
      npm: ['typescript', ''],
      files: [{ path: '/workspace/f.txt', content: 'hi' }, { path: '', content: 'skip-me' }],
    })
    expect(payload.name).toBe('pi via gateway')
    expect(payload.spec.harness).toEqual({
      type: 'pi',
      model: 'gpt-5',
      backend: { base_url: 'https://gateway.example.com' },
      args: [],
    })
    expect(payload.spec.environment.npm).toEqual(['typescript'])
    expect(payload.spec.environment.files).toEqual([
      { path: '/workspace/f.txt', content_b64: btoa('hi') },
    ])
  })

  it('omits provider_id from the payload when Custom backend is selected', () => {
    const { container } = render(<New />)
    fireEvent.submit(container.querySelector('form')!)
    const transformer = transform.mock.calls[0][0]
    const payload = transformer({ ...formData, name: 'custom profile' })
    expect(payload).not.toHaveProperty('provider_id')
  })

  it('adds top-level provider_id to the payload when a provider is selected', () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: true, json: async () => ({ models: [], error: null }) }),
    )
    const { container } = render(<New providers={[ANTHROPIC_PROVIDER]} />)
    const field = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: '1' } })

    fireEvent.submit(container.querySelector('form')!)
    const transformer = transform.mock.calls[0][0]
    const payload = transformer({ ...formData, name: 'via provider' })
    expect(payload.provider_id).toBe(1)
  })

  it('fills base_url/api_key_ref and fetches models when a provider is selected', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: true, json: async () => ({ models: ['claude-sonnet-5'], error: null }) }),
    )
    render(<New providers={[ANTHROPIC_PROVIDER]} />)
    const field = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: '1' } })

    expect(setData).toHaveBeenCalledWith('base_url', 'https://api.anthropic.com')
    expect(setData).toHaveBeenCalledWith('api_key_ref', 'op://vault/anthropic')
    expect(fetch).toHaveBeenCalledWith('/providers/1/models')
    await waitFor(() => {
      const modelField = screen.getByText('Model').closest('div')!
      expect(within(modelField).getByText('claude-sonnet-5')).not.toBeNull()
    })
  })

  it('filters providers by the current harness type and resets on an incompatible switch', () => {
    render(<New providers={[ANTHROPIC_PROVIDER]} />)
    const providerField = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(providerField).getByRole('combobox'), { target: { value: '1' } })
    expect(within(providerField).getByRole('combobox')).toHaveValue('1')

    const harnessField = screen.getByText('Harness type').closest('div')!
    fireEvent.change(within(harnessField).getByRole('combobox'), { target: { value: 'pi' } })

    expect(within(providerField).getByRole('combobox')).toHaveValue('custom')
  })
})

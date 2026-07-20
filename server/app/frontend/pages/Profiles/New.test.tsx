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
})

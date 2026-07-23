import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi, beforeEach } from 'vitest'
import type { Provider } from '@/types'

let formData: Record<string, unknown>
let formErrors: Record<string, string>
// Mirrors @inertiajs/react's setData overloads: a (key, value) pair, or a
// functional updater — the pi-extension sync helper uses the latter so it
// always reads current data at resolve time.
const setData = vi.fn(
  (
    keyOrUpdater: string | ((prev: Record<string, unknown>) => Record<string, unknown>),
    value?: unknown,
  ) => {
    formData =
      typeof keyOrUpdater === 'function' ? keyOrUpdater(formData) : { ...formData, [keyOrUpdater]: value }
  },
)
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
    debs: [],
    npm: [],
    gems: [],
    mise: [],
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

const OPENAI_PROVIDER: Provider = {
  id: 2,
  name: 'openrouter',
  base_url: 'https://openrouter.ai/api/v1',
  api_key_ref: null,
  flavors: ['openai'],
}

const KEYED_OPENAI_PROVIDER: Provider = {
  id: 3,
  name: 'gateway',
  base_url: 'https://gateway.example.com',
  api_key_ref: 'op://vault/gateway',
  flavors: ['openai'],
}

function stubFetch({
  models = { models: [], error: null },
  extension,
}: {
  models?: { models: string[]; error: string | null }
  extension: { extension: { path: string; content: string; env_key: string | null } | null; error: string | null }
}) {
  vi.stubGlobal(
    'fetch',
    vi.fn((url: string) => {
      if (url.endsWith('/pi_extension')) {
        return Promise.resolve({ ok: true, json: async () => extension })
      }
      return Promise.resolve({ ok: true, json: async () => models })
    }),
  )
}

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
    expect(screen.getByText('Debian packages')).not.toBeNull()
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

  it('defaults to an ANTHROPIC_API_KEY env row with a non-empty placeholder', () => {
    formData = { ...formData, env: [['ANTHROPIC_API_KEY', 'unused-for-keyless-backends']] }
    render(<New />)
    const field = screen.getByText('Environment variables').closest('div')!
    expect(within(field).getByDisplayValue('ANTHROPIC_API_KEY')).not.toBeNull()
    expect(within(field).getByDisplayValue('unused-for-keyless-backends')).not.toBeNull()
  })

  it('explains why the ANTHROPIC_API_KEY row exists', () => {
    render(<New />)
    expect(
      screen.getByText(/claude CLI refuses to start without ANTHROPIC_API_KEY/),
    ).not.toBeNull()
  })

  it('an untouched form transforms to a payload containing the default env var', () => {
    formData = { ...formData, env: [['ANTHROPIC_API_KEY', 'unused-for-keyless-backends']] }
    const { container } = render(<New />)
    fireEvent.submit(container.querySelector('form')!)

    const transformer = transform.mock.calls[0][0]
    const payload = transformer(formData)
    expect(payload.environment.env).toEqual({ ANTHROPIC_API_KEY: 'unused-for-keyless-backends' })
  })

  it('the default ANTHROPIC_API_KEY row is removable via the existing remove control', () => {
    formData = { ...formData, env: [['ANTHROPIC_API_KEY', 'unused-for-keyless-backends']] }
    render(<New />)
    const field = screen.getByText('Environment variables').closest('div')!
    fireEvent.click(within(field).getByRole('button', { name: 'Remove' }))
    expect(setData).toHaveBeenCalledWith('env', [])
  })

  it('renders a harness type select defaulting to claude', () => {
    render(<New />)
    expect(screen.getByText('Harness type')).not.toBeNull()
    const field = screen.getByText('Harness type').closest('div')!
    expect(within(field).getByRole('combobox')).toHaveValue('claude')
  })

  it('renders npm and files fields', () => {
    render(<New />)
    expect(screen.getByText('npm packages')).not.toBeNull()
    expect(screen.getByText('Files')).not.toBeNull()
  })

  it('adding a files row appends an empty path/content entry via setData', () => {
    render(<New />)
    const field = screen.getByText('Files').closest('div')!
    fireEvent.click(within(field).getByRole('button', { name: 'Add file' }))
    expect(setData).toHaveBeenCalledWith('files', [{ path: '', content: '' }])
  })

  it('submits npm and files under environment, base64-encoding file content', () => {
    const { container } = render(<New />)
    fireEvent.submit(container.querySelector('form')!)
    const transformer = transform.mock.calls[0][0]
    const payload = transformer({
      ...formData,
      npm: ['typescript', ''],
      files: [{ path: '/workspace/.pi/config.toml', content: 'hello' }],
    })
    expect(payload.environment.npm).toEqual(['typescript'])
    expect(payload.environment.files).toEqual([
      { path: '/workspace/.pi/config.toml', content_b64: btoa('hello') },
    ])
  })

  it('switching harness type to pi drives the submitted harness.type', () => {
    const { container } = render(<New />)
    fireEvent.submit(container.querySelector('form')!)
    const transformer = transform.mock.calls[0][0]
    const payload = transformer({ ...formData, harness_type: 'pi' })
    expect(payload.harness.type).toBe('pi')
  })

  it('switching to pi removes the ANTHROPIC_API_KEY row only while it holds the seeded placeholder', () => {
    formData = { ...formData, env: [['ANTHROPIC_API_KEY', 'unused-for-keyless-backends']] }
    render(<New />)
    const field = screen.getByText('Harness type').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: 'pi' } })
    expect(setData).toHaveBeenCalledWith('env', [])
    expect(setData).toHaveBeenCalledWith('harness_type', 'pi')
  })

  it('switching to pi never clobbers a user-edited ANTHROPIC_API_KEY value', () => {
    formData = { ...formData, env: [['ANTHROPIC_API_KEY', 'sk-real-secret']] }
    render(<New />)
    const field = screen.getByText('Harness type').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: 'pi' } })
    expect(setData).not.toHaveBeenCalledWith('env', [])
    expect(setData).toHaveBeenCalledWith('harness_type', 'pi')
  })

  it('shows the pi-appropriate explanation when pi is selected', () => {
    formData = { ...formData, harness_type: 'pi' }
    render(<New />)
    expect(screen.getByText(/executor injects no ANTHROPIC env for pi/)).not.toBeNull()
  })

  it('renders no profile selector when the profiles prop is empty', () => {
    render(<New />)
    expect(screen.queryByText('Load from profile')).toBeNull()
  })

  it('selecting a profile prefills the form from its spec', () => {
    const profile = {
      id: 1,
      name: 'pi via gateway',
      harness_type: 'pi',
      spec: {
        harness: {
          type: 'pi',
          model: 'gpt-5',
          backend: { base_url: 'https://gateway.example.com', api_key_ref: 'op://vault/item' },
          args: ['--flag'],
        },
        environment: {
          env: { FOO: 'bar' },
          secrets: [{ ref: 'op://vault/secret', name: 'SECRET' }],
          debs: ['git'],
          npm: ['typescript'],
          gems: ['rails'],
          mise: ['ruby@3.4'],
          files: [{ path: '/workspace/f.txt', content_b64: btoa('hi') }],
          permissions: { network: true, mounts: ['/host:/container'] },
        },
      },
    }
    render(<New profiles={[profile]} />)
    const field = screen.getByText('Load from profile').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: '1' } })

    expect(setData).toHaveBeenCalledWith('harness_type', 'pi')
    expect(setData).toHaveBeenCalledWith('harness_model', 'gpt-5')
    expect(setData).toHaveBeenCalledWith('base_url', 'https://gateway.example.com')
    expect(setData).toHaveBeenCalledWith('api_key_ref', 'op://vault/item')
    expect(setData).toHaveBeenCalledWith('args', ['--flag'])
    expect(setData).toHaveBeenCalledWith('env', [['FOO', 'bar']])
    expect(setData).toHaveBeenCalledWith('secrets', [['op://vault/secret', 'SECRET']])
    expect(setData).toHaveBeenCalledWith('debs', ['git'])
    expect(setData).toHaveBeenCalledWith('npm', ['typescript'])
    expect(setData).toHaveBeenCalledWith('gems', ['rails'])
    expect(setData).toHaveBeenCalledWith('mise', ['ruby@3.4'])
    expect(setData).toHaveBeenCalledWith('files', [{ path: '/workspace/f.txt', content: 'hi' }])
    expect(setData).toHaveBeenCalledWith('network', true)
    expect(setData).toHaveBeenCalledWith('mounts', ['/host:/container'])
  })

  it('prefills the debs field from an old-shape profile carrying deps instead of debs', () => {
    const profile = {
      id: 1,
      name: 'legacy profile',
      harness_type: 'claude',
      spec: {
        harness: {
          type: 'claude',
          model: 'claude-sonnet-5',
          backend: { base_url: 'https://api.example.com' },
          args: [],
        },
        environment: {
          env: {},
          secrets: [],
          deps: ['git', 'curl'],
          npm: [],
          files: [],
          permissions: {},
        },
      },
    }
    render(<New profiles={[profile]} />)
    const field = screen.getByText('Load from profile').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: '1' } })

    expect(setData).toHaveBeenCalledWith('debs', ['git', 'curl'])
  })

  it('renders only providers compatible with the current (claude) harness', () => {
    render(<New providers={[ANTHROPIC_PROVIDER, OPENAI_PROVIDER]} />)
    const field = screen.getByText('Provider').closest('div')!
    const select = within(field).getByRole('combobox')
    expect(within(select).getByText('anthropic-direct')).not.toBeNull()
    expect(within(select).queryByText('openrouter')).toBeNull()
  })

  it('selecting a provider fills base_url/api_key_ref and fetches models', async () => {
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

  it('falls back to free-text model input and a muted message on fetch error', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: true, json: async () => ({ models: [], error: 'fetch_failed' }) }),
    )
    render(<New providers={[ANTHROPIC_PROVIDER]} />)
    const field = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: '1' } })

    await waitFor(() => {
      const modelField = screen.getByText('Model').closest('div')!
      expect(within(modelField).getByPlaceholderText('claude-sonnet-5')).not.toBeNull()
      expect(within(modelField).getByText('Could not load models for this provider.')).not.toBeNull()
    })
  })

  it('locks base_url/api_key_ref to read-only while a provider is selected', () => {
    render(<New providers={[ANTHROPIC_PROVIDER]} />)
    const field = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: '1' } })

    const urlField = screen.getByText('Backend base URL').closest('div')!
    expect(within(urlField).getByPlaceholderText('https://api.example.com/v1')).toHaveAttribute(
      'readonly',
    )
  })

  it('resets an incompatible selected provider to Custom backend when harness type switches', () => {
    render(<New providers={[ANTHROPIC_PROVIDER]} />)
    const providerField = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(providerField).getByRole('combobox'), { target: { value: '1' } })
    expect(within(providerField).getByRole('combobox')).toHaveValue('1')

    const harnessField = screen.getByText('Harness type').closest('div')!
    fireEvent.change(within(harnessField).getByRole('combobox'), { target: { value: 'pi' } })

    expect(within(providerField).getByRole('combobox')).toHaveValue('custom')
  })

  it('applyProfile resets the provider select to Custom backend', () => {
    const profile = {
      id: 1,
      name: 'pi via gateway',
      harness_type: 'pi',
      spec: {
        harness: {
          type: 'pi',
          model: 'gpt-5',
          backend: { base_url: 'https://gateway.example.com', api_key_ref: null },
          args: [],
        },
        environment: { env: {}, secrets: [], deps: [], npm: [], files: [], permissions: {} },
      },
    }
    render(<New profiles={[profile]} providers={[ANTHROPIC_PROVIDER]} />)
    const providerField = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(providerField).getByRole('combobox'), { target: { value: '1' } })
    expect(within(providerField).getByRole('combobox')).toHaveValue('1')

    const profileField = screen.getByText('Load from profile').closest('div')!
    fireEvent.change(within(profileField).getByRole('combobox'), { target: { value: '1' } })

    expect(within(providerField).getByRole('combobox')).toHaveValue('custom')
  })

  it('submits a byte-unchanged payload with a provider selected', () => {
    const { container } = render(<New providers={[ANTHROPIC_PROVIDER]} />)
    const field = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: '1' } })

    fireEvent.submit(container.querySelector('form')!)
    const transformer = transform.mock.calls[0][0]
    const payload = transformer({
      ...formData,
      prompt: 'do the thing',
      harness_model: 'claude-sonnet-5',
      base_url: 'https://api.anthropic.com',
      api_key_ref: 'op://vault/anthropic',
      env: [['FOO', 'bar']],
      secrets: [],
    })
    expect(payload).toEqual({
      harness: {
        type: 'claude',
        model: 'claude-sonnet-5',
        backend: { base_url: 'https://api.anthropic.com', api_key_ref: 'op://vault/anthropic' },
        args: [],
      },
      prompt: 'do the thing',
      environment: {
        env: { FOO: 'bar' },
        secrets: [],
        debs: [],
        npm: [],
        gems: [],
        mise: [],
        files: [],
        permissions: { network: false, mounts: [] },
      },
    })
  })

  it('submits debs/gems/mise under environment and never submits deps', () => {
    const { container } = render(<New />)
    fireEvent.submit(container.querySelector('form')!)
    const transformer = transform.mock.calls[0][0]
    const payload = transformer({
      ...formData,
      debs: ['git', ''],
      gems: ['rails', ''],
      mise: ['ruby@3.4', ''],
    })
    expect(payload.environment.debs).toEqual(['git'])
    expect(payload.environment.gems).toEqual(['rails'])
    expect(payload.environment.mise).toEqual(['ruby@3.4'])
    expect(payload.environment).not.toHaveProperty('deps')
  })

  it('prefills the form from prefill_spec on mount, field-for-field via the shared mapping', () => {
    const prefillSpec = {
      harness: {
        type: 'pi',
        model: 'gpt-5',
        backend: { base_url: 'https://gateway.example.com', api_key_ref: 'op://vault/item' },
        args: ['--flag'],
      },
      prompt: 'do the re-run thing',
      environment: {
        env: { FOO: 'bar' },
        secrets: [{ ref: 'op://vault/secret', name: 'SECRET' }],
        debs: ['git'],
        npm: ['typescript'],
        gems: ['rails'],
        mise: ['ruby@3.4'],
        files: [{ path: '/workspace/f.txt', content_b64: btoa('hi') }],
        permissions: { network: true, mounts: ['/host:/container'] },
      },
    }
    render(<New prefill_spec={prefillSpec} />)

    expect(setData).toHaveBeenCalledWith('harness_type', 'pi')
    expect(setData).toHaveBeenCalledWith('harness_model', 'gpt-5')
    expect(setData).toHaveBeenCalledWith('base_url', 'https://gateway.example.com')
    expect(setData).toHaveBeenCalledWith('api_key_ref', 'op://vault/item')
    expect(setData).toHaveBeenCalledWith('args', ['--flag'])
    expect(setData).toHaveBeenCalledWith('env', [['FOO', 'bar']])
    expect(setData).toHaveBeenCalledWith('secrets', [['op://vault/secret', 'SECRET']])
    expect(setData).toHaveBeenCalledWith('debs', ['git'])
    expect(setData).toHaveBeenCalledWith('npm', ['typescript'])
    expect(setData).toHaveBeenCalledWith('gems', ['rails'])
    expect(setData).toHaveBeenCalledWith('mise', ['ruby@3.4'])
    expect(setData).toHaveBeenCalledWith('files', [{ path: '/workspace/f.txt', content: 'hi' }])
    expect(setData).toHaveBeenCalledWith('network', true)
    expect(setData).toHaveBeenCalledWith('mounts', ['/host:/container'])
    expect(setData).toHaveBeenCalledWith('prompt', 'do the re-run thing')
  })

  it('leaves the form at its untouched defaults when prefill_spec is absent', () => {
    render(<New />)
    expect(setData).not.toHaveBeenCalled()
  })

  it('offers opencode as a harness type', () => {
    render(<New />)
    const field = screen.getByText('Harness type').closest('div')!
    expect(within(field).getByText('opencode')).not.toBeNull()
  })

  it('filters provider options for opencode to the openai flavor', () => {
    formData = { ...formData, harness_type: 'opencode' }
    render(<New providers={[ANTHROPIC_PROVIDER, OPENAI_PROVIDER]} />)
    const field = screen.getByText('Provider').closest('div')!
    const select = within(field).getByRole('combobox')
    expect(within(select).getByText('openrouter')).not.toBeNull()
    expect(within(select).queryByText('anthropic-direct')).toBeNull()
  })

  it('selecting a provider under harness pi adds the generated extension as a files row', async () => {
    stubFetch({
      extension: {
        extension: { path: '/root/.pi/agent/extensions/openrouter.ts', content: 'export default {}', env_key: null },
        error: null,
      },
    })
    formData = { ...formData, harness_type: 'pi', files: [] }
    render(<New providers={[OPENAI_PROVIDER]} />)
    const field = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: '2' } })

    expect(fetch).toHaveBeenCalledWith('/providers/2/pi_extension')
    await waitFor(() => {
      expect(formData.files).toEqual([
        { path: '/root/.pi/agent/extensions/openrouter.ts', content: 'export default {}' },
      ])
    })
  })

  it('adds a secrets row for a key-bearing provider under harness pi', async () => {
    stubFetch({
      extension: {
        extension: {
          path: '/root/.pi/agent/extensions/gateway.ts',
          content: 'export default {}',
          env_key: 'PI_PROVIDER_API_KEY',
        },
        error: null,
      },
    })
    formData = { ...formData, harness_type: 'pi', files: [], secrets: [] }
    render(<New providers={[KEYED_OPENAI_PROVIDER]} />)
    const field = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: '3' } })

    await waitFor(() => {
      expect(formData.secrets).toEqual([['op://vault/gateway', 'PI_PROVIDER_API_KEY']])
    })
  })

  it('a provider switch replaces the generated rows while leaving hand-added rows alone', async () => {
    stubFetch({
      extension: {
        extension: { path: '/root/.pi/agent/extensions/openrouter.ts', content: 'v1', env_key: null },
        error: null,
      },
    })
    formData = {
      ...formData,
      harness_type: 'pi',
      files: [{ path: '/workspace/hand-added.txt', content: 'mine' }],
    }
    render(<New providers={[OPENAI_PROVIDER, KEYED_OPENAI_PROVIDER]} />)
    const field = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: '2' } })

    await waitFor(() => {
      expect(formData.files).toEqual([
        { path: '/workspace/hand-added.txt', content: 'mine' },
        { path: '/root/.pi/agent/extensions/openrouter.ts', content: 'v1' },
      ])
    })
    setData.mockClear()

    stubFetch({
      extension: {
        extension: { path: '/root/.pi/agent/extensions/gateway.ts', content: 'v2', env_key: null },
        error: null,
      },
    })
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: '3' } })

    await waitFor(() => {
      expect(formData.files).toEqual([
        { path: '/workspace/hand-added.txt', content: 'mine' },
        { path: '/root/.pi/agent/extensions/gateway.ts', content: 'v2' },
      ])
    })
  })

  it('an error response from pi_extension adds nothing and leaves the form usable', async () => {
    stubFetch({ extension: { extension: null, error: 'timeout' } })
    formData = { ...formData, harness_type: 'pi', files: [] }
    render(<New providers={[OPENAI_PROVIDER]} />)
    const field = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: '2' } })

    await waitFor(() => {
      expect(screen.getByText(/Could not generate the pi extension/)).not.toBeNull()
    })
    expect(formData.files).toEqual([])
  })

  it('selecting Custom backend adds nothing', () => {
    formData = { ...formData, harness_type: 'pi', files: [] }
    render(<New providers={[OPENAI_PROVIDER]} />)
    const field = screen.getByText('Provider').closest('div')!
    fireEvent.change(within(field).getByRole('combobox'), { target: { value: 'custom' } })

    expect(setData).not.toHaveBeenCalled()
  })
})

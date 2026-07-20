import { afterEach, describe, expect, it, vi } from 'vitest'
import { compatibleProviders, fetchPiExtension, fetchProviderModels, REQUIRED_FLAVOR } from '@/lib/providers'
import type { Provider } from '@/types'

afterEach(() => {
  vi.unstubAllGlobals()
})

function provider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 1,
    name: 'openrouter',
    base_url: 'https://openrouter.ai/api/v1',
    api_key_ref: null,
    flavors: [],
    ...overrides,
  }
}

describe('REQUIRED_FLAVOR', () => {
  it('maps each harness to its required backend flavor', () => {
    expect(REQUIRED_FLAVOR).toEqual({ claude: 'anthropic', pi: 'openai', opencode: 'openai' })
  })
})

describe('compatibleProviders', () => {
  it('keeps only providers carrying the harness-required flavor', () => {
    const anthropic = provider({ id: 1, flavors: ['anthropic'] })
    const openai = provider({ id: 2, flavors: ['openai'] })
    expect(compatibleProviders([anthropic, openai], 'claude')).toEqual([anthropic])
    expect(compatibleProviders([anthropic, openai], 'pi')).toEqual([openai])
    expect(compatibleProviders([anthropic, openai], 'opencode')).toEqual([openai])
  })

  it('includes a multi-flavor provider for any harness it covers', () => {
    const both = provider({ flavors: ['anthropic', 'openai'] })
    expect(compatibleProviders([both], 'claude')).toEqual([both])
    expect(compatibleProviders([both], 'pi')).toEqual([both])
  })

  it('returns [] for an unknown harness type', () => {
    expect(compatibleProviders([provider({ flavors: ['anthropic'] })], 'bogus')).toEqual([])
  })
})

describe('fetchProviderModels', () => {
  it('returns the parsed {models, error} shape on success', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: true, json: async () => ({ models: ['a', 'b'], error: null }) }),
    )
    expect(await fetchProviderModels(7)).toEqual({ models: ['a', 'b'], error: null })
    expect(fetch).toHaveBeenCalledWith('/providers/7/models')
  })

  it('passes through a server-reported error token at HTTP 200', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: true, json: async () => ({ models: [], error: 'unreachable' }) }),
    )
    expect(await fetchProviderModels(7)).toEqual({ models: [], error: 'unreachable' })
  })

  it('maps a non-2xx response to fetch_failed without throwing', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, json: async () => ({}) }))
    expect(await fetchProviderModels(7)).toEqual({ models: [], error: 'fetch_failed' })
  })

  it('maps a network failure to fetch_failed without throwing', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('offline')))
    await expect(fetchProviderModels(7)).resolves.toEqual({ models: [], error: 'fetch_failed' })
  })
})

describe('fetchPiExtension', () => {
  it('returns the parsed {extension, error} shape on success', async () => {
    const extension = { path: '/root/.pi/agent/extensions/openrouter.ts', content: 'export default {}', env_key: 'PI_PROVIDER_API_KEY' }
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: true, json: async () => ({ extension, error: null }) }),
    )
    expect(await fetchPiExtension(7)).toEqual({ extension, error: null })
    expect(fetch).toHaveBeenCalledWith('/providers/7/pi_extension')
  })

  it('passes through a server-reported error token at HTTP 200', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: true, json: async () => ({ extension: null, error: 'secret_resolution_failed' }) }),
    )
    expect(await fetchPiExtension(7)).toEqual({ extension: null, error: 'secret_resolution_failed' })
  })

  it('maps a non-2xx response to fetch_failed without throwing', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, json: async () => ({}) }))
    expect(await fetchPiExtension(7)).toEqual({ extension: null, error: 'fetch_failed' })
  })

  it('maps a network failure to fetch_failed without throwing', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('offline')))
    await expect(fetchPiExtension(7)).resolves.toEqual({ extension: null, error: 'fetch_failed' })
  })
})

import { afterEach, describe, expect, it, vi } from 'vitest'
import { CUSTOM_BACKEND, syncPiExtension, type FileRow, type GeneratedPi } from '@/lib/pi-extension'
import type { Provider } from '@/types'

afterEach(() => {
  vi.unstubAllGlobals()
})

const PROVIDER: Provider = {
  id: 3,
  name: 'gateway',
  base_url: 'https://gateway.example.com',
  api_key_ref: 'op://vault/gateway',
  flavors: ['openai'],
}

type FormData = { files: FileRow[]; secrets: [string, string][] }

// A form double whose setData mirrors @inertiajs/react's functional overload
// (data: (previous: TForm) => TForm) => void, applied synchronously against a
// mutable snapshot — enough to prove read-at-resolve-time behavior.
function fakeForm(initial: FormData) {
  let data = initial
  const setData = vi.fn((updater: (prev: FormData) => FormData) => {
    data = updater(data)
  })
  return { setData, current: () => data }
}

function deferredFetch() {
  let resolve!: (body: unknown) => void
  const promise = new Promise((r) => {
    resolve = r
  })
  vi.stubGlobal(
    'fetch',
    vi.fn(() => promise.then((body) => ({ ok: true, json: async () => body }))),
  )
  return resolve
}

describe('syncPiExtension', () => {
  it('reads form data at resolve time, so an edit made mid-fetch survives', async () => {
    const resolve = deferredFetch()
    const form = fakeForm({ files: [], secrets: [] })
    const setGeneratedPi = vi.fn()

    syncPiExtension('pi', '3', [PROVIDER], null, setGeneratedPi, vi.fn(), form.setData)

    // A hand edit lands while the fetch is still in flight.
    form.setData((prev) => ({
      ...prev,
      files: [...prev.files, { path: '/workspace/hand-added.txt', content: 'mine' }],
    }))

    resolve({
      extension: {
        path: '/root/.pi/agent/extensions/gateway.ts',
        content: 'export default {}',
        env_key: 'PI_PROVIDER_API_KEY',
      },
      error: null,
    })
    await vi.waitFor(() => expect(setGeneratedPi).toHaveBeenCalled())

    expect(form.current().files).toEqual([
      { path: '/workspace/hand-added.txt', content: 'mine' },
      { path: '/root/.pi/agent/extensions/gateway.ts', content: 'export default {}' },
    ])
    expect(form.current().secrets).toEqual([['op://vault/gateway', 'PI_PROVIDER_API_KEY']])
  })

  it('adds a files row without a secret for a keyless provider', async () => {
    const resolve = deferredFetch()
    const form = fakeForm({ files: [], secrets: [] })
    const keyless: Provider = { ...PROVIDER, api_key_ref: null }

    syncPiExtension('pi', '3', [keyless], null, vi.fn(), vi.fn(), form.setData)
    resolve({
      extension: { path: '/root/.pi/agent/extensions/gateway.ts', content: 'export default {}', env_key: null },
      error: null,
    })

    await vi.waitFor(() =>
      expect(form.current().files).toEqual([
        { path: '/root/.pi/agent/extensions/gateway.ts', content: 'export default {}' },
      ]),
    )
    expect(form.current().secrets).toEqual([])
  })

  it('removes the previously generated rows before adding the new ones, leaving hand-added rows alone', async () => {
    const resolve = deferredFetch()
    const stale: GeneratedPi = {
      path: '/root/.pi/agent/extensions/old.ts',
      ref: 'op://vault/old',
      envKey: 'OLD_KEY',
    }
    const form = fakeForm({
      files: [
        { path: '/workspace/hand-added.txt', content: 'mine' },
        { path: '/root/.pi/agent/extensions/old.ts', content: 'v1' },
      ],
      secrets: [['op://vault/old', 'OLD_KEY']],
    })

    syncPiExtension('pi', '3', [PROVIDER], stale, vi.fn(), vi.fn(), form.setData)
    resolve({
      extension: { path: '/root/.pi/agent/extensions/gateway.ts', content: 'v2', env_key: 'NEW_KEY' },
      error: null,
    })

    await vi.waitFor(() =>
      expect(form.current().files).toEqual([
        { path: '/workspace/hand-added.txt', content: 'mine' },
        { path: '/root/.pi/agent/extensions/gateway.ts', content: 'v2' },
      ]),
    )
    expect(form.current().secrets).toEqual([['op://vault/gateway', 'NEW_KEY']])
  })

  it('reports the error and adds nothing when the extension fetch fails', async () => {
    const resolve = deferredFetch()
    const form = fakeForm({ files: [], secrets: [] })
    const setPiExtensionError = vi.fn()

    syncPiExtension('pi', '3', [PROVIDER], null, vi.fn(), setPiExtensionError, form.setData)
    resolve({ extension: null, error: 'timeout' })

    await vi.waitFor(() => expect(setPiExtensionError).toHaveBeenCalledWith('timeout'))
    expect(form.current().files).toEqual([])
  })

  it('does nothing for a non-pi harness or the custom backend sentinel', () => {
    const form = fakeForm({ files: [], secrets: [] })
    syncPiExtension('claude', '3', [PROVIDER], null, vi.fn(), vi.fn(), form.setData)
    syncPiExtension('pi', CUSTOM_BACKEND, [PROVIDER], null, vi.fn(), vi.fn(), form.setData)
    expect(form.setData).not.toHaveBeenCalled()
  })
})

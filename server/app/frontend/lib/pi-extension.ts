import type { SetDataByMethod } from '@inertiajs/react'
import type { Provider } from '@/types'
import { fetchPiExtension } from '@/lib/providers'

export const CUSTOM_BACKEND = 'custom'

export type FileRow = { path: string; content: string }

// Tracks the currently auto-added pi extension files/secrets row so a provider
// switch (or leaving harness pi) can remove exactly those rows without
// touching anything the user added by hand.
export type GeneratedPi =
  | { path: string; ref: string; envKey: string }
  | { path: string; ref: null; envKey: null }

export type PiExtensionFormData = {
  files: FileRow[]
  secrets: [string, string][]
}

// Removes the previously auto-added files/secrets rows (if any), then, if
// newHarnessType is pi and providerId names a provider, fetches and adds its
// generated extension. Hand-added rows are never touched. Reads form data at
// resolve time (functional setData) rather than the caller's snapshot at call
// time, so an edit made while the fetch is in flight isn't clobbered. `setData`
// takes the files/secrets slice specifically — pass a wrapper around the
// page's full-form setData(prev => ...) that merges the slice back in.
export function syncPiExtension(
  newHarnessType: string,
  providerId: string,
  providers: Provider[],
  generatedPi: GeneratedPi | null,
  setGeneratedPi: (pi: GeneratedPi | null) => void,
  setPiExtensionError: (error: string | null) => void,
  setData: SetDataByMethod<PiExtensionFormData>,
) {
  setPiExtensionError(null)
  const stale = generatedPi
  if (stale) {
    setData((prev) => ({
      ...prev,
      files: prev.files.filter((f) => f.path !== stale.path),
      secrets: stale.ref
        ? prev.secrets.filter(([ref, name]) => !(ref === stale.ref && name === stale.envKey))
        : prev.secrets,
    }))
    setGeneratedPi(null)
  }

  if (newHarnessType !== 'pi' || providerId === CUSTOM_BACKEND) return
  const provider = providers.find((p) => String(p.id) === providerId)
  if (!provider) return

  fetchPiExtension(provider.id).then(({ extension, error }) => {
    if (!extension) {
      setPiExtensionError(error)
      return
    }
    setData((prev) => ({
      ...prev,
      files: [...prev.files, { path: extension.path, content: extension.content }],
    }))
    if (extension.env_key && provider.api_key_ref) {
      const ref = provider.api_key_ref
      const envKey = extension.env_key
      setData((prev) => ({ ...prev, secrets: [...prev.secrets, [ref, envKey]] }))
      setGeneratedPi({ path: extension.path, ref, envKey })
    } else {
      setGeneratedPi({ path: extension.path, ref: null, envKey: null })
    }
  })
}

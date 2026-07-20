import type { PiExtensionResponse, Provider } from '@/types'

// A provider is usable by a harness only if it carries the flavor that
// harness's backend protocol speaks — Claude's Anthropic-shaped API, pi and
// opencode's OpenAI-shaped one.
export const REQUIRED_FLAVOR: Record<string, string> = {
  claude: 'anthropic',
  pi: 'openai',
  opencode: 'openai',
}

export function compatibleProviders(providers: Provider[], harnessType: string): Provider[] {
  const flavor = REQUIRED_FLAVOR[harnessType]
  if (!flavor) return []
  return providers.filter((p) => p.flavors.includes(flavor))
}

export type ProviderModels = { models: string[]; error: string | null }

// Wraps GET /providers/:id/models — the frozen {models, error} shape at HTTP
// 200 both ways. Never throws into React: a non-2xx response or a network
// failure (offline, aborted, malformed JSON) collapses to the same fallback
// the caller already renders for a server-reported error.
export async function fetchProviderModels(id: number): Promise<ProviderModels> {
  try {
    const response = await fetch(`/providers/${id}/models`)
    if (!response.ok) return { models: [], error: 'fetch_failed' }
    return (await response.json()) as ProviderModels
  } catch {
    return { models: [], error: 'fetch_failed' }
  }
}

// Wraps GET /providers/:id/pi_extension — the frozen {extension, error} shape
// at HTTP 200 both ways. Never throws into React, mirroring fetchProviderModels.
export async function fetchPiExtension(id: number): Promise<PiExtensionResponse> {
  try {
    const response = await fetch(`/providers/${id}/pi_extension`)
    if (!response.ok) return { extension: null, error: 'fetch_failed' }
    return (await response.json()) as PiExtensionResponse
  } catch {
    return { extension: null, error: 'fetch_failed' }
  }
}

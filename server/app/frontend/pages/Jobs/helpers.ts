import type { EnvironmentSpec, HarnessSpec } from '@/types'

// UTF-8 safe base64 roundtrip for file content typed into a textarea
// (browser btoa/atob only handle Latin1 directly).
export function encodeBase64(content: string): string {
  return btoa(unescape(encodeURIComponent(content)))
}

export function decodeBase64(content: string): string {
  return decodeURIComponent(escape(atob(content)))
}

// The New form fields derived from a harness+environment spec — the shape
// shared by both ProfileSpec (profile application) and JobSpec (re-run
// prefill, spec.harness/spec.environment). Kept in one place so the two
// callers can't drift apart.
export type SpecFormFields = {
  harness_type: string
  harness_model: string
  base_url: string
  api_key_ref: string
  args: string[]
  env: [string, string][]
  secrets: [string, string][]
  debs: string[]
  npm: string[]
  gems: string[]
  mise: string[]
  files: { path: string; content: string }[]
  network: boolean
  mounts: string[]
}

export function specFormFields(spec: { harness: HarnessSpec; environment: EnvironmentSpec }): SpecFormFields {
  return {
    harness_type: spec.harness.type,
    harness_model: spec.harness.model,
    base_url: spec.harness.backend.base_url,
    api_key_ref: spec.harness.backend.api_key_ref ?? '',
    args: spec.harness.args ?? [],
    env: Object.entries(spec.environment.env ?? {}),
    secrets: (spec.environment.secrets ?? []).map(({ ref, name }): [string, string] => [ref, name]),
    debs: spec.environment.debs ?? spec.environment.deps ?? [],
    npm: spec.environment.npm ?? [],
    gems: spec.environment.gems ?? [],
    mise: spec.environment.mise ?? [],
    files: (spec.environment.files ?? []).map((f) => ({ path: f.path, content: decodeBase64(f.content_b64) })),
    network: spec.environment.permissions?.network ?? false,
    mounts: spec.environment.permissions?.mounts ?? [],
  }
}

export type BadgeVariant = 'default' | 'secondary' | 'destructive' | 'outline'

// The five states in config/db/migrate/20260701000000_create_jobs.rb's status check
// constraint.
export const STATUS_VARIANT: Record<string, BadgeVariant> = {
  queued: 'outline',
  running: 'default',
  succeeded: 'secondary',
  failed: 'destructive',
  canceled: 'outline',
}

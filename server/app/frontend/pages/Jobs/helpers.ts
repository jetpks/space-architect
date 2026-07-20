// UTF-8 safe base64 roundtrip for file content typed into a textarea
// (browser btoa/atob only handle Latin1 directly).
export function encodeBase64(content: string): string {
  return btoa(unescape(encodeURIComponent(content)))
}

export function decodeBase64(content: string): string {
  return decodeURIComponent(escape(atob(content)))
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

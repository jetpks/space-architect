export type BadgeVariant = 'default' | 'secondary' | 'destructive' | 'outline'

export const STATUS_VARIANT: Record<string, BadgeVariant> = {
  pending: 'outline',
  live: 'default',
  complete: 'secondary',
  failed: 'destructive',
  active: 'default',
}

export const VERDICT_VARIANT: Record<string, BadgeVariant> = {
  continue: 'default',
  complete: 'secondary',
  blocked: 'destructive',
  abandoned: 'outline',
}

export const KIND_VARIANT: Record<string, BadgeVariant> = {
  brief: 'outline',
  iteration: 'secondary',
  report: 'default',
}

export function relativeTime(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime()
  const minutes = Math.floor(diff / 60_000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
}

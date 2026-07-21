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

// Display precision is milliseconds, but only when the wire value actually
// carries non-zero fractional seconds — otherwise showing ".000" fabricates
// precision the source never had. Compose the wall-clock by shifting the UTC
// epoch — host timezone is never read.
export function formatAbsolute(isoUtc: string, offsetSeconds?: number | null): string {
  const offset = offsetSeconds ?? 0
  const shifted = new Date(new Date(isoUtc).getTime() + offset * 1000)
  const Y = shifted.getUTCFullYear()
  const M = String(shifted.getUTCMonth() + 1).padStart(2, '0')
  const D = String(shifted.getUTCDate()).padStart(2, '0')
  const h = String(shifted.getUTCHours()).padStart(2, '0')
  const m = String(shifted.getUTCMinutes()).padStart(2, '0')
  const s = String(shifted.getUTCSeconds()).padStart(2, '0')

  const fractionDigits = isoUtc.match(/\.(\d+)/)?.[1] ?? ''
  const hasRealMillis = Number(fractionDigits.padEnd(3, '0').slice(0, 3)) !== 0
  const ms = hasRealMillis ? `.${String(shifted.getUTCMilliseconds()).padStart(3, '0')}` : ''

  const tz =
    offsetSeconds == null || offsetSeconds === 0
      ? 'Z'
      : `${offset < 0 ? '-' : '+'}${String(Math.floor(Math.abs(offset) / 3600)).padStart(2, '0')}:${String(
          Math.floor((Math.abs(offset) % 3600) / 60),
        ).padStart(2, '0')}`

  return `${Y}-${M}-${D}T${h}:${m}:${s}${ms}${tz}`
}

export function timeLabel(isoUtc: string, offsetSeconds?: number | null): string {
  return `${relativeTime(isoUtc)} · ${formatAbsolute(isoUtc, offsetSeconds)}`
}

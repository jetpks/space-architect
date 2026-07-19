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

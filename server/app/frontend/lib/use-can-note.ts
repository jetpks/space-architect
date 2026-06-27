import { usePage } from '@inertiajs/react'
import type { Conversation, SharedProps } from '@/types'

// May the current viewer compose notes on this page's conversation? Signed in
// AND granted note access (owner or note grant) — visibility alone is not
// enough, so every compose affordance gates on this rather than current_user.
// Pages without a conversation prop answer false.
export function useCanNote(): boolean {
  const props = usePage<SharedProps & { conversation?: Conversation }>().props
  return !!props.current_user && !!props.conversation?.can_note
}

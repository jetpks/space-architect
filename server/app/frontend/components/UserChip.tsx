import { Avatar, AvatarFallback, AvatarImage } from '@/components/ui/avatar'
import { cn } from '@/lib/utils'

// A small identity stamp — GitHub avatar + name — used wherever a human shows
// up in the transcript: the owner on prompts, the noter on note cards. Falls
// back to an initial when there's no avatar (dev users, org-less accounts).
export default function UserChip({
  name,
  avatarUrl,
  className,
}: {
  name: string
  avatarUrl: string | null
  className?: string
}) {
  return (
    <span className={cn('inline-flex min-w-0 items-center gap-1.5', className)}>
      <Avatar className="size-4">
        {avatarUrl && <AvatarImage src={avatarUrl} alt="" />}
        <AvatarFallback className="text-[9px]">{name[0]?.toUpperCase()}</AvatarFallback>
      </Avatar>
      <span className="truncate">{name}</span>
    </span>
  )
}

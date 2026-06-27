import {
  ChevronDown,
  ChevronUp,
  ChevronsDown,
  ChevronsUp,
  ClipboardCopy,
  Code,
  Link as LinkIcon,
  MessageSquarePlus,
  MoreHorizontal,
} from 'lucide-react'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { useCanNote } from '@/lib/use-can-note'

// Best-effort clipboard write — the menu is a convenience, so a denied permission
// or an insecure context fails quietly rather than throwing into the click handler.
function copy(text: string) {
  void navigator.clipboard?.writeText(text)
}

// A same-page permalink to an element's anchor id (the `#turn-…`, `#round-…`,
// `#message-…` ids the transcript already hangs on its rows for TOC jumps).
function permalink(anchor: string): string {
  const { origin, pathname } = window.location
  return `${origin}${pathname}#${anchor}`
}

// The one menu every bar in the transcript hangs in its top-right corner. It always
// renders the SAME rows in the same order — fold this, fold all, source / copy / link,
// annotate — so the menu reads identically everywhere; a bar simply omits the props it
// can't yet honor and those rows show up disabled rather than missing. (Several are
// stubbed disabled on purpose until the backing actions land — see the call sites.)
// Both fold directions are always present, with the one matching the current state
// disabled, so the row a control lives on never jumps around as you open and close.
export default function BarMenu({
  fold,
  all,
  source,
  copySource,
  anchor,
  annotate,
  label = 'Row actions',
}: {
  // Fold this one element; `noun` names it ("turn", "round", "tool"). Omit on bars
  // that aren't independently foldable (prompt / thoughts / a terminal message).
  fold?: {
    expanded: boolean
    onExpand: () => void
    onCollapse: () => void
    noun: string
  }
  // Fold every sibling of a scope at once; `noun` names the scope ("turns", "rounds").
  all?: { onExpand: () => void; onCollapse: () => void; noun: string }
  // Toggle an inline source view, with its current shown-state for the label.
  source?: { shown: boolean; onToggle: () => void }
  // Produce the raw source text to drop on the clipboard (blocks as JSON).
  copySource?: () => string
  // Anchor id for "Copy link" (e.g. `turn-5`).
  anchor?: string
  // Open the annotation form (additionally gated on note access below).
  annotate?: () => void
  // Accessible name for the trigger.
  label?: string
}) {
  const canNote = useCanNote()
  const canAnnotate = Boolean(annotate && canNote)

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          aria-label={label}
          className="flex h-5 w-5 shrink-0 items-center justify-center rounded text-muted-foreground outline-none transition-colors hover:bg-foreground/5 hover:text-foreground"
        >
          <MoreHorizontal className="size-4" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="min-w-48">
        <DropdownMenuItem disabled={!fold || fold.expanded} onClick={fold?.onExpand}>
          <ChevronDown /> Expand{fold ? ` ${fold.noun}` : ''}
        </DropdownMenuItem>
        <DropdownMenuItem disabled={!fold || !fold.expanded} onClick={fold?.onCollapse}>
          <ChevronUp /> Collapse{fold ? ` ${fold.noun}` : ''}
        </DropdownMenuItem>

        <DropdownMenuSeparator />

        <DropdownMenuItem disabled={!all} onClick={all?.onExpand}>
          <ChevronsDown /> Expand all{all ? ` ${all.noun}` : ''}
        </DropdownMenuItem>
        <DropdownMenuItem disabled={!all} onClick={all?.onCollapse}>
          <ChevronsUp /> Collapse all{all ? ` ${all.noun}` : ''}
        </DropdownMenuItem>

        <DropdownMenuSeparator />

        <DropdownMenuItem disabled={!source} onClick={source?.onToggle}>
          <Code /> {source?.shown ? 'Hide source' : 'Source'}
        </DropdownMenuItem>
        <DropdownMenuItem disabled={!copySource} onClick={() => copySource && copy(copySource())}>
          <ClipboardCopy /> Copy source
        </DropdownMenuItem>
        <DropdownMenuItem disabled={!anchor} onClick={() => anchor && copy(permalink(anchor))}>
          <LinkIcon /> Copy link
        </DropdownMenuItem>

        <DropdownMenuSeparator />

        <DropdownMenuItem disabled={!canAnnotate} onClick={annotate}>
          <MessageSquarePlus /> Add note
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

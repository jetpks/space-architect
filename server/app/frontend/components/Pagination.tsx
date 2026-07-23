import { router } from '@inertiajs/react'
import { Button } from '@/components/ui/button'
import type { Pagination as PaginationData } from '@/types'

type Props = { pagination: PaginationData; path: string }

// Drives Prev/Next for an index page's `?page=N` prop via an Inertia visit.
// No other query state exists on these paths, so the target is just `path?page=N`.
export default function Pagination({ pagination, path }: Props) {
  const { page, has_more } = pagination
  if (page === 1 && !has_more) return null

  return (
    <div className="mt-4 flex items-center justify-between">
      <Button
        variant="outline"
        size="sm"
        disabled={page === 1}
        onClick={() => router.visit(`${path}?page=${page - 1}`)}
      >
        Prev
      </Button>
      <Button
        variant="outline"
        size="sm"
        disabled={!has_more}
        onClick={() => router.visit(`${path}?page=${page + 1}`)}
      >
        Next
      </Button>
    </div>
  )
}

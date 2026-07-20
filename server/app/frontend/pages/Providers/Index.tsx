import { Head, Link, router } from '@inertiajs/react'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import AppLayout from '@/layouts/AppLayout'

// Not yet in shared types — providers are a new resource this iteration.
export type Provider = {
  id: number
  name: string
  base_url: string
  api_key_ref: string | null
  flavors: string[]
}

type Props = { providers: Provider[] }

export default function Index({ providers }: Props) {
  return (
    <AppLayout>
      <Head title="Providers" />

      <div className="mb-4 flex items-center justify-between">
        <h1 className="text-2xl font-bold">Providers</h1>
        <Button asChild size="sm">
          <Link href="/providers/new">New provider</Link>
        </Button>
      </div>

      {providers.length === 0 ? (
        <p className="text-sm text-muted-foreground">No providers yet.</p>
      ) : (
        <ul className="divide-y divide-border">
          {providers.map((provider) => (
            <li key={provider.id} className="flex items-center justify-between py-3">
              <div>
                <p className="font-medium">{provider.name}</p>
                <p className="text-xs text-muted-foreground">{provider.base_url}</p>
                <div className="mt-1 flex flex-wrap items-center gap-1">
                  {provider.flavors.map((flavor) => (
                    <Badge key={flavor} variant="secondary">
                      {flavor}
                    </Badge>
                  ))}
                  <Badge variant="outline">{provider.api_key_ref ? 'op ref' : 'keyless'}</Badge>
                </div>
              </div>

              <AlertDialog>
                <AlertDialogTrigger asChild>
                  <Button size="sm" variant="destructive">
                    Delete
                  </Button>
                </AlertDialogTrigger>
                <AlertDialogContent>
                  <AlertDialogHeader>
                    <AlertDialogTitle>Delete this provider?</AlertDialogTitle>
                    <AlertDialogDescription>
                      This permanently removes "{provider.name}".
                    </AlertDialogDescription>
                  </AlertDialogHeader>
                  <AlertDialogFooter>
                    <AlertDialogCancel>Cancel</AlertDialogCancel>
                    <AlertDialogAction
                      onClick={() => router.post(`/providers/${provider.id}/delete`)}
                    >
                      Delete
                    </AlertDialogAction>
                  </AlertDialogFooter>
                </AlertDialogContent>
              </AlertDialog>
            </li>
          ))}
        </ul>
      )}
    </AppLayout>
  )
}

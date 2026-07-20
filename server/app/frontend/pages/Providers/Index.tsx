import { useState } from 'react'
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
import { fetchProviderModels } from '@/lib/providers'
import type { Provider } from '@/types'

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
            <ProviderRow key={provider.id} provider={provider} />
          ))}
        </ul>
      )}
    </AppLayout>
  )
}

function ProviderRow({ provider }: { provider: Provider }) {
  const [preview, setPreview] = useState<{ models: string[]; error: string | null } | null>(null)
  const [loading, setLoading] = useState(false)

  async function previewModels() {
    setLoading(true)
    setPreview(await fetchProviderModels(provider.id))
    setLoading(false)
  }

  return (
    <li className="flex items-center justify-between py-3">
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
        {preview &&
          (preview.error || preview.models.length === 0 ? (
            <p className="mt-1 text-xs text-muted-foreground">No models available.</p>
          ) : (
            <p className="mt-1 text-xs text-muted-foreground">{preview.models.join(', ')}</p>
          ))}
      </div>

      <div className="flex items-center gap-2">
        <Button size="sm" variant="outline" disabled={loading} onClick={previewModels}>
          Preview models
        </Button>

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
              <AlertDialogAction onClick={() => router.post(`/providers/${provider.id}/delete`)}>
                Delete
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </div>
    </li>
  )
}

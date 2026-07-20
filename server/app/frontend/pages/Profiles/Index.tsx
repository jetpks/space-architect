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
import { Button } from '@/components/ui/button'
import AppLayout from '@/layouts/AppLayout'
import type { Profile } from '@/types'

type Props = { profiles: Profile[] }

export default function Index({ profiles }: Props) {
  return (
    <AppLayout>
      <Head title="Profiles" />

      <div className="mb-4 flex items-center justify-between">
        <h1 className="text-2xl font-bold">Profiles</h1>
        <Button asChild size="sm">
          <Link href="/profiles/new">New profile</Link>
        </Button>
      </div>

      {profiles.length === 0 ? (
        <p className="text-sm text-muted-foreground">No profiles yet.</p>
      ) : (
        <ul className="divide-y divide-border">
          {profiles.map((profile) => (
            <li key={profile.id} className="flex items-center justify-between py-3">
              <div>
                <p className="font-medium">{profile.name}</p>
                <p className="text-xs text-muted-foreground">
                  {profile.harness_type} · {profile.spec.harness.model} ·{' '}
                  {Object.keys(profile.spec.environment.env ?? {}).length} env ·{' '}
                  {(profile.spec.environment.npm ?? []).length} npm ·{' '}
                  {(profile.spec.environment.files ?? []).length} files
                </p>
              </div>

              <AlertDialog>
                <AlertDialogTrigger asChild>
                  <Button size="sm" variant="destructive">
                    Delete
                  </Button>
                </AlertDialogTrigger>
                <AlertDialogContent>
                  <AlertDialogHeader>
                    <AlertDialogTitle>Delete this profile?</AlertDialogTitle>
                    <AlertDialogDescription>
                      This permanently removes "{profile.name}". Jobs already created from it are
                      unaffected.
                    </AlertDialogDescription>
                  </AlertDialogHeader>
                  <AlertDialogFooter>
                    <AlertDialogCancel>Cancel</AlertDialogCancel>
                    <AlertDialogAction onClick={() => router.post(`/profiles/${profile.id}/delete`)}>
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

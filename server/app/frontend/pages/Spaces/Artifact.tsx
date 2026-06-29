import { Head } from '@inertiajs/react'
import AppLayout from '@/layouts/AppLayout'
import Markdown from '@/components/Markdown'
import type { SpaceArtifactDetail } from '@/types'

type Props = {
  space: { id: number; slug: string; title: string }
  artifact: SpaceArtifactDetail
}

export default function Artifact({ space, artifact }: Props) {
  return (
    <AppLayout>
      <Head title={`${artifact.title} — ${space.title}`} />

      <header className="mb-4 border-b border-border pb-4">
        <h1 className="text-2xl font-bold">{artifact.title}</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          {space.title} · {artifact.kind}
        </p>
        <p className="font-mono text-xs text-muted-foreground">{artifact.path}</p>
      </header>

      <div className="overflow-x-auto max-w-full">
        <Markdown text={artifact.raw} />
      </div>
    </AppLayout>
  )
}

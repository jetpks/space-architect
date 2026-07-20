import { Head, useForm } from '@inertiajs/react'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import AppLayout from '@/layouts/AppLayout'

export default function New() {
  // Flat form data keeps error keys aligned with Rails (`source_file`);
  // transform wraps the payload as conversation[source_file] on the wire.
  const form = useForm<{ source_file: File | null }>({ source_file: null })

  function submit(e: React.FormEvent) {
    e.preventDefault()
    form.transform((data) => ({ conversation: data }))
    form.post('/conversations')
  }

  return (
    <AppLayout>
      <Head title="Upload conversation" />
      <h1 className="text-2xl font-bold">Upload a conversation</h1>
      <p className="mt-1 text-sm text-muted-foreground">
        Drop in a Claude Code transcript (<code className="font-mono">.jsonl</code> from{' '}
        <code className="font-mono">~/.claude/projects/…</code>) or a Codex CLI rollout (from{' '}
        <code className="font-mono">~/.codex/sessions/…</code>). We'll import the turns in the
        background.
      </p>

      <form onSubmit={submit} className="mt-4 max-w-md space-y-4">
        <div className="space-y-1">
          <Label htmlFor="source_file">Transcript file</Label>
          <input
            id="source_file"
            type="file"
            accept=".jsonl,application/jsonl,application/json,text/plain"
            onChange={(e) => form.setData('source_file', e.target.files?.[0] ?? null)}
            className="block w-full text-sm text-muted-foreground file:mr-3 file:rounded-md file:border-0 file:bg-primary file:px-3 file:py-2 file:text-primary-foreground"
          />
          {form.errors.source_file && (
            <p className="text-sm text-destructive">{form.errors.source_file}</p>
          )}
        </div>

        <Button type="submit" disabled={form.processing}>
          Upload
        </Button>
      </form>
    </AppLayout>
  )
}

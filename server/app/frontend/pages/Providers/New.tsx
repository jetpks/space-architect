import { Head, useForm } from '@inertiajs/react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import AppLayout from '@/layouts/AppLayout'

const FLAVORS = ['openai', 'anthropic'] as const

type FormData = {
  name: string
  base_url: string
  api_key_ref: string
  flavors: string[]
}

const INITIAL_DATA: FormData = {
  name: '',
  base_url: '',
  api_key_ref: '',
  flavors: [],
}

export default function New() {
  const form = useForm<FormData>(INITIAL_DATA)

  function submit(e: React.FormEvent) {
    e.preventDefault()
    form.transform((data) => ({
      name: data.name,
      base_url: data.base_url,
      ...(data.api_key_ref.trim() ? { api_key_ref: data.api_key_ref } : {}),
      flavors: data.flavors,
    }))
    form.post('/providers')
  }

  return (
    <AppLayout>
      <Head title="New provider" />
      <h1 className="text-2xl font-bold">New provider</h1>
      <p className="mt-1 text-sm text-muted-foreground">
        Register an inference backend that jobs and profiles can target.
      </p>

      <form onSubmit={submit} className="mt-4 max-w-2xl space-y-6">
        <Field label="Name" error={form.errors.name}>
          <Input
            value={form.data.name}
            onChange={(e) => form.setData('name', e.target.value)}
            placeholder="openrouter"
            required
          />
        </Field>

        <Field label="Base URL" error={form.errors.base_url}>
          <Input
            value={form.data.base_url}
            onChange={(e) => form.setData('base_url', e.target.value)}
            placeholder="https://api.example.com/v1"
            required
          />
        </Field>

        <div className="space-y-1">
          <Field label="API key ref (optional)" error={form.errors.api_key_ref}>
            <Input
              value={form.data.api_key_ref}
              onChange={(e) => form.setData('api_key_ref', e.target.value)}
              placeholder="op://vault/item"
            />
          </Field>
          <p className="text-sm text-muted-foreground">
            Providers store a ref only, never keys — paste the op:// path, not the raw secret.
          </p>
        </div>

        <Field label="Flavors" error={form.errors.flavors}>
          <div className="space-y-2">
            {FLAVORS.map((flavor) => (
              <Label key={flavor} className="font-normal">
                <Checkbox
                  checked={form.data.flavors.includes(flavor)}
                  onCheckedChange={(checked) =>
                    form.setData(
                      'flavors',
                      checked === true
                        ? [...form.data.flavors, flavor]
                        : form.data.flavors.filter((f) => f !== flavor),
                    )
                  }
                />
                {flavor}
              </Label>
            ))}
          </div>
        </Field>

        <Button type="submit" disabled={form.processing}>
          Save provider
        </Button>
      </form>
    </AppLayout>
  )
}

function Field({
  label,
  error,
  children,
}: {
  label: string
  error?: string
  children: React.ReactNode
}) {
  return (
    <div className="space-y-1">
      <Label>{label}</Label>
      {children}
      {error && <p className="text-sm text-destructive">{error}</p>}
    </div>
  )
}

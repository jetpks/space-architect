import { Plus, X } from 'lucide-react'
import { Head, useForm } from '@inertiajs/react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import AppLayout from '@/layouts/AppLayout'
import { encodeBase64 } from '@/pages/Jobs/helpers'

type FileRow = { path: string; content: string }

type FormData = {
  name: string
  harness_type: string
  harness_model: string
  base_url: string
  api_key_ref: string
  args: string[]
  env: [string, string][]
  secrets: [string, string][]
  deps: string[]
  npm: string[]
  files: FileRow[]
  network: boolean
  mounts: string[]
}

const INITIAL_DATA: FormData = {
  name: '',
  harness_type: 'claude',
  harness_model: '',
  base_url: '',
  api_key_ref: '',
  args: [],
  env: [],
  secrets: [],
  deps: [],
  npm: [],
  files: [],
  network: false,
  mounts: [],
}

export default function New() {
  const form = useForm<FormData>(INITIAL_DATA)

  function submit(e: React.FormEvent) {
    e.preventDefault()
    form.transform((data) => ({
      name: data.name,
      spec: {
        harness: {
          type: data.harness_type,
          model: data.harness_model,
          backend: {
            base_url: data.base_url,
            ...(data.api_key_ref.trim() ? { api_key_ref: data.api_key_ref } : {}),
          },
          args: data.args.filter((a) => a.trim() !== ''),
        },
        environment: {
          env: Object.fromEntries(data.env.filter(([k]) => k.trim() !== '')),
          secrets: data.secrets
            .filter(([ref, name]) => ref.trim() !== '' && name.trim() !== '')
            .map(([ref, name]) => ({ ref, name })),
          deps: data.deps.filter((d) => d.trim() !== ''),
          npm: data.npm.filter((n) => n.trim() !== ''),
          files: data.files
            .filter((f) => f.path.trim() !== '')
            .map((f) => ({ path: f.path, content_b64: encodeBase64(f.content) })),
          permissions: {
            network: data.network,
            mounts: data.mounts.filter((m) => m.trim() !== ''),
          },
        },
      },
    }))
    form.post('/profiles')
  }

  return (
    <AppLayout>
      <Head title="New profile" />
      <h1 className="text-2xl font-bold">New profile</h1>
      <p className="mt-1 text-sm text-muted-foreground">
        Save a reusable harness + environment configuration to prefill future jobs.
      </p>

      <form onSubmit={submit} className="mt-4 max-w-2xl space-y-6">
        <Field label="Name" error={form.errors.name}>
          <Input
            value={form.data.name}
            onChange={(e) => form.setData('name', e.target.value)}
            placeholder="pi via gateway"
            required
          />
        </Field>

        <Field label="Harness type" error={form.errors.harness_type}>
          <select
            value={form.data.harness_type}
            onChange={(e) => form.setData('harness_type', e.target.value)}
            className={SELECT_CLASS}
          >
            <option value="claude">claude</option>
            <option value="pi">pi</option>
          </select>
        </Field>

        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Model" error={form.errors.harness_model}>
            <Input
              value={form.data.harness_model}
              onChange={(e) => form.setData('harness_model', e.target.value)}
              placeholder="claude-sonnet-5"
              required
            />
          </Field>

          <Field label="Backend base URL" error={form.errors.base_url}>
            <Input
              value={form.data.base_url}
              onChange={(e) => form.setData('base_url', e.target.value)}
              placeholder="https://api.example.com/v1"
              required
            />
          </Field>
        </div>

        <Field label="Backend API key ref (optional)" error={form.errors.api_key_ref}>
          <Input
            value={form.data.api_key_ref}
            onChange={(e) => form.setData('api_key_ref', e.target.value)}
            placeholder="op://vault/item"
          />
        </Field>

        <ListField
          label="Harness args"
          values={form.data.args}
          onChange={(args) => form.setData('args', args)}
          placeholder="--flag"
          error={form.errors.args}
        />

        <PairField
          label="Environment variables"
          rows={form.data.env}
          onChange={(env) => form.setData('env', env)}
          keyPlaceholder="NAME"
          valuePlaceholder="value"
          addLabel="Add variable"
          error={form.errors.env}
        />

        <PairField
          label="Secrets"
          rows={form.data.secrets}
          onChange={(secrets) => form.setData('secrets', secrets)}
          keyPlaceholder="op://vault/item"
          valuePlaceholder="ENV_NAME"
          addLabel="Add secret"
          error={form.errors.secrets}
        />

        <ListField
          label="Dependencies"
          values={form.data.deps}
          onChange={(deps) => form.setData('deps', deps)}
          placeholder="git"
          error={form.errors.deps}
        />

        <ListField
          label="npm packages"
          values={form.data.npm}
          onChange={(npm) => form.setData('npm', npm)}
          placeholder="typescript"
          error={form.errors.npm}
        />

        <div className="space-y-1">
          <FilesField
            label="Files"
            rows={form.data.files}
            onChange={(files) => form.setData('files', files)}
            error={form.errors.files}
          />
          <p className="text-sm text-muted-foreground">
            Profiles store config only, never keys — secrets ride op:// refs above, not file
            content.
          </p>
        </div>

        <Field label="Permissions" error={form.errors.network}>
          <Label className="font-normal">
            <Checkbox
              checked={form.data.network}
              onCheckedChange={(checked) => form.setData('network', checked === true)}
            />
            Allow network access
          </Label>
        </Field>

        <ListField
          label="Mounts (optional)"
          values={form.data.mounts}
          onChange={(mounts) => form.setData('mounts', mounts)}
          placeholder="/host/path:/container/path"
          error={form.errors.mounts}
        />

        <Button type="submit" disabled={form.processing}>
          Save profile
        </Button>
      </form>
    </AppLayout>
  )
}

const SELECT_CLASS =
  'flex h-8 w-full min-w-0 rounded-lg border border-input bg-transparent px-2.5 py-1 text-base transition-colors outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 md:text-sm dark:bg-input/30'

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

// A dynamic list of single-value rows (harness args, deps, mounts, npm).
function ListField({
  label,
  values,
  onChange,
  placeholder,
  error,
}: {
  label: string
  values: string[]
  onChange: (values: string[]) => void
  placeholder?: string
  error?: string
}) {
  return (
    <Field label={label} error={error}>
      <div className="space-y-2">
        {values.map((value, i) => (
          <div key={i} className="flex gap-2">
            <Input
              value={value}
              placeholder={placeholder}
              onChange={(e) => onChange(values.map((v, j) => (j === i ? e.target.value : v)))}
            />
            <RemoveRowButton onClick={() => onChange(values.filter((_, j) => j !== i))} />
          </div>
        ))}
        <AddRowButton onClick={() => onChange([...values, ''])} />
      </div>
    </Field>
  )
}

// A dynamic list of two-value rows (env key/value, secret ref/name).
function PairField({
  label,
  rows,
  onChange,
  keyPlaceholder,
  valuePlaceholder,
  addLabel,
  error,
}: {
  label: string
  rows: [string, string][]
  onChange: (rows: [string, string][]) => void
  keyPlaceholder: string
  valuePlaceholder: string
  addLabel: string
  error?: string
}) {
  return (
    <Field label={label} error={error}>
      <div className="space-y-2">
        {rows.map(([key, value], i) => (
          <div key={i} className="flex gap-2">
            <Input
              value={key}
              placeholder={keyPlaceholder}
              onChange={(e) => onChange(rows.map((r, j) => (j === i ? [e.target.value, r[1]] : r)))}
            />
            <Input
              value={value}
              placeholder={valuePlaceholder}
              onChange={(e) => onChange(rows.map((r, j) => (j === i ? [r[0], e.target.value] : r)))}
            />
            <RemoveRowButton onClick={() => onChange(rows.filter((_, j) => j !== i))} />
          </div>
        ))}
        <AddRowButton label={addLabel} onClick={() => onChange([...rows, ['', '']])} />
      </div>
    </Field>
  )
}

// A dynamic list of sandbox files: an absolute path plus its content, typed
// in as plain text and base64-encoded only at submit time.
function FilesField({
  label,
  rows,
  onChange,
  error,
}: {
  label: string
  rows: FileRow[]
  onChange: (rows: FileRow[]) => void
  error?: string
}) {
  return (
    <Field label={label} error={error}>
      <div className="space-y-3">
        {rows.map((row, i) => (
          <div key={i} className="space-y-2 rounded-lg border border-input p-2">
            <div className="flex gap-2">
              <Input
                value={row.path}
                placeholder="/workspace/.pi/config.toml"
                onChange={(e) =>
                  onChange(rows.map((r, j) => (j === i ? { ...r, path: e.target.value } : r)))
                }
              />
              <RemoveRowButton onClick={() => onChange(rows.filter((_, j) => j !== i))} />
            </div>
            <Textarea
              value={row.content}
              placeholder="file contents"
              rows={3}
              onChange={(e) =>
                onChange(rows.map((r, j) => (j === i ? { ...r, content: e.target.value } : r)))
              }
            />
          </div>
        ))}
        <AddRowButton label="Add file" onClick={() => onChange([...rows, { path: '', content: '' }])} />
      </div>
    </Field>
  )
}

function AddRowButton({ onClick, label = 'Add' }: { onClick: () => void; label?: string }) {
  return (
    <Button type="button" variant="outline" size="sm" onClick={onClick}>
      <Plus className="size-4" /> {label}
    </Button>
  )
}

function RemoveRowButton({ onClick }: { onClick: () => void }) {
  return (
    <Button
      type="button"
      variant="ghost"
      size="icon"
      onClick={onClick}
      aria-label="Remove"
    >
      <X className="size-4" />
    </Button>
  )
}

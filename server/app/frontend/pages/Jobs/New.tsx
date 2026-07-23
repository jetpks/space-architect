import { useState } from 'react'
import { Plus, X } from 'lucide-react'
import { Head, useForm } from '@inertiajs/react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import AppLayout from '@/layouts/AppLayout'
import { compatibleProviders, fetchProviderModels } from '@/lib/providers'
import { CUSTOM_BACKEND, syncPiExtension, type FileRow, type GeneratedPi } from '@/lib/pi-extension'
import type { Profile, Provider } from '@/types'
import { decodeBase64, encodeBase64 } from './helpers'

type FormData = {
  harness_type: string
  prompt: string
  harness_model: string
  base_url: string
  api_key_ref: string
  args: string[]
  env: [string, string][]
  secrets: [string, string][]
  debs: string[]
  npm: string[]
  gems: string[]
  mise: string[]
  files: FileRow[]
  network: boolean
  mounts: string[]
}

const ANTHROPIC_ROW: [string, string] = ['ANTHROPIC_API_KEY', 'unused-for-keyless-backends']

const INITIAL_DATA: FormData = {
  harness_type: 'claude',
  prompt: '',
  harness_model: '',
  base_url: '',
  api_key_ref: '',
  args: [],
  env: [ANTHROPIC_ROW],
  secrets: [],
  debs: [],
  npm: [],
  gems: [],
  mise: [],
  files: [],
  network: false,
  mounts: [],
}

type Props = { profiles?: Profile[]; providers?: Provider[] }

export default function New({ profiles = [], providers = [] }: Props) {
  const form = useForm<FormData>(INITIAL_DATA)
  const [selectedProfileId, setSelectedProfileId] = useState('')
  const [selectedProviderId, setSelectedProviderId] = useState(CUSTOM_BACKEND)
  const [modelOptions, setModelOptions] = useState<string[]>([])
  const [modelsError, setModelsError] = useState<string | null>(null)
  const [generatedPi, setGeneratedPi] = useState<GeneratedPi | null>(null)
  const [piExtensionError, setPiExtensionError] = useState<string | null>(null)
  const harnessType = form.data.harness_type ?? 'claude'
  const providerOptions = compatibleProviders(providers, harnessType)

  function syncPi(newHarnessType: string, providerId: string) {
    syncPiExtension(
      newHarnessType,
      providerId,
      providers,
      generatedPi,
      setGeneratedPi,
      setPiExtensionError,
      (updater) => form.setData((prev) => ({ ...prev, ...updater(prev) })),
    )
  }

  function selectProvider(id: string) {
    setSelectedProviderId(id)
    setModelOptions([])
    setModelsError(null)

    const provider = providerOptions.find((p) => String(p.id) === id)
    if (!provider) {
      syncPi(harnessType, CUSTOM_BACKEND)
      return
    }
    form.setData('base_url', provider.base_url)
    form.setData('api_key_ref', provider.api_key_ref ?? '')

    fetchProviderModels(provider.id).then(({ models, error }) => {
      setModelOptions(models)
      setModelsError(error)
    })

    syncPi(harnessType, id)
  }

  function onHarnessTypeChange(newType: string) {
    if (newType !== harnessType) {
      const env = form.data.env
      const anthropicIndex = env.findIndex(([key]) => key === ANTHROPIC_ROW[0])
      if (newType === 'pi' && anthropicIndex !== -1 && env[anthropicIndex][1] === ANTHROPIC_ROW[1]) {
        form.setData('env', env.filter((_, i) => i !== anthropicIndex))
      } else if (newType === 'claude' && anthropicIndex === -1) {
        form.setData('env', [...env, ANTHROPIC_ROW])
      }
      form.setData('harness_type', newType)

      const stillCompatible =
        selectedProviderId !== CUSTOM_BACKEND &&
        compatibleProviders(providers, newType).some((p) => String(p.id) === selectedProviderId)
      if (!stillCompatible && selectedProviderId !== CUSTOM_BACKEND) {
        setSelectedProviderId(CUSTOM_BACKEND)
        setModelOptions([])
        setModelsError(null)
      }
      syncPi(newType, stillCompatible ? selectedProviderId : CUSTOM_BACKEND)
    }
  }

  function applyProfile(id: string) {
    setSelectedProfileId(id)
    const profile = profiles.find((p) => String(p.id) === id)
    if (!profile) return
    const spec = profile.spec

    setSelectedProviderId(CUSTOM_BACKEND)
    setModelOptions([])
    setModelsError(null)
    setGeneratedPi(null)
    setPiExtensionError(null)

    form.setData('harness_type', profile.harness_type)
    form.setData('harness_model', spec.harness.model)
    form.setData('base_url', spec.harness.backend.base_url)
    form.setData('api_key_ref', spec.harness.backend.api_key_ref ?? '')
    form.setData('args', spec.harness.args ?? [])
    form.setData('env', Object.entries(spec.environment.env ?? {}))
    form.setData(
      'secrets',
      (spec.environment.secrets ?? []).map(({ ref, name }): [string, string] => [ref, name]),
    )
    form.setData('debs', spec.environment.debs ?? spec.environment.deps ?? [])
    form.setData('npm', spec.environment.npm ?? [])
    form.setData('gems', spec.environment.gems ?? [])
    form.setData('mise', spec.environment.mise ?? [])
    form.setData(
      'files',
      (spec.environment.files ?? []).map((f) => ({ path: f.path, content: decodeBase64(f.content_b64) })),
    )
    form.setData('network', spec.environment.permissions?.network ?? false)
    form.setData('mounts', spec.environment.permissions?.mounts ?? [])
  }

  function submit(e: React.FormEvent) {
    e.preventDefault()
    form.transform((data) => ({
      harness: {
        type: data.harness_type ?? 'claude',
        model: data.harness_model,
        backend: {
          base_url: data.base_url,
          ...(data.api_key_ref.trim() ? { api_key_ref: data.api_key_ref } : {}),
        },
        args: data.args.filter((a) => a.trim() !== ''),
      },
      prompt: data.prompt,
      environment: {
        env: Object.fromEntries(data.env.filter(([k]) => k.trim() !== '')),
        secrets: data.secrets
          .filter(([ref, name]) => ref.trim() !== '' && name.trim() !== '')
          .map(([ref, name]) => ({ ref, name })),
        debs: data.debs.filter((d) => d.trim() !== ''),
        npm: (data.npm ?? []).filter((n) => n.trim() !== ''),
        gems: (data.gems ?? []).filter((g) => g.trim() !== ''),
        mise: (data.mise ?? []).filter((m) => m.trim() !== ''),
        files: (data.files ?? [])
          .filter((f) => f.path.trim() !== '')
          .map((f) => ({ path: f.path, content_b64: encodeBase64(f.content) })),
        permissions: {
          network: data.network,
          mounts: data.mounts.filter((m) => m.trim() !== ''),
        },
      },
    }))
    form.post('/jobs')
  }

  return (
    <AppLayout>
      <Head title="New job" />
      <h1 className="text-2xl font-bold">New job</h1>
      <p className="mt-1 text-sm text-muted-foreground">
        Enqueue a Claude Code harness run against a backend of your choosing.
      </p>

      <form onSubmit={submit} className="mt-4 max-w-2xl space-y-6">
        {profiles.length > 0 && (
          <Field label="Load from profile">
            <select
              value={selectedProfileId}
              onChange={(e) => applyProfile(e.target.value)}
              className={SELECT_CLASS}
            >
              <option value="">Select a profile…</option>
              {profiles.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
          </Field>
        )}

        <Field label="Harness type" error={form.errors.harness_type}>
          <select
            value={harnessType}
            onChange={(e) => onHarnessTypeChange(e.target.value)}
            className={SELECT_CLASS}
          >
            <option value="claude">claude</option>
            <option value="pi">pi</option>
            <option value="opencode">opencode</option>
          </select>
        </Field>

        <Field label="Prompt" error={form.errors.prompt}>
          <Textarea
            value={form.data.prompt}
            onChange={(e) => form.setData('prompt', e.target.value)}
            rows={6}
            required
          />
        </Field>

        <Field label="Provider">
          <select
            value={selectedProviderId}
            onChange={(e) => selectProvider(e.target.value)}
            className={SELECT_CLASS}
          >
            <option value={CUSTOM_BACKEND}>Custom backend</option>
            {providerOptions.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
        </Field>

        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Model" error={form.errors.harness_model}>
            {modelOptions.length > 0 ? (
              <select
                value={form.data.harness_model}
                onChange={(e) => form.setData('harness_model', e.target.value)}
                className={SELECT_CLASS}
              >
                <option value="">Select a model…</option>
                {modelOptions.map((model) => (
                  <option key={model} value={model}>
                    {model}
                  </option>
                ))}
              </select>
            ) : (
              <>
                <Input
                  value={form.data.harness_model}
                  onChange={(e) => form.setData('harness_model', e.target.value)}
                  placeholder="claude-sonnet-5"
                  required
                />
                {selectedProviderId !== CUSTOM_BACKEND && (
                  <p className="text-sm text-muted-foreground">
                    {modelsError ? 'Could not load models for this provider.' : 'No models available.'}
                  </p>
                )}
              </>
            )}
          </Field>

          <Field label="Backend base URL" error={form.errors.base_url}>
            <Input
              value={form.data.base_url}
              onChange={(e) => form.setData('base_url', e.target.value)}
              placeholder="https://api.example.com/v1"
              readOnly={selectedProviderId !== CUSTOM_BACKEND}
              required
            />
          </Field>
        </div>

        <Field label="Backend API key ref (optional)" error={form.errors.api_key_ref}>
          <Input
            value={form.data.api_key_ref}
            onChange={(e) => form.setData('api_key_ref', e.target.value)}
            placeholder="op://vault/item"
            readOnly={selectedProviderId !== CUSTOM_BACKEND}
          />
        </Field>

        <ListField
          label="Harness args"
          values={form.data.args}
          onChange={(args) => form.setData('args', args)}
          placeholder="--flag"
          error={form.errors.args}
        />

        <div className="space-y-1">
          <PairField
            label="Environment variables"
            rows={form.data.env}
            onChange={(env) => form.setData('env', env)}
            keyPlaceholder="NAME"
            valuePlaceholder="value"
            addLabel="Add variable"
            error={form.errors.env}
          />
          <p className="text-sm text-muted-foreground">
            {harnessType === 'pi'
              ? "pi's backend config rides the profile's extension file; the executor injects no ANTHROPIC env for pi."
              : 'The claude CLI refuses to start without ANTHROPIC_API_KEY set; keyless backends (the gateway) ignore it.'}
          </p>
        </div>

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
          label="Debian packages"
          values={form.data.debs}
          onChange={(debs) => form.setData('debs', debs)}
          placeholder="git"
          error={form.errors.debs}
        />

        <ListField
          label="npm packages"
          values={form.data.npm ?? []}
          onChange={(npm) => form.setData('npm', npm)}
          placeholder="typescript"
          error={form.errors.npm}
        />

        <ListField
          label="Ruby gems"
          values={form.data.gems ?? []}
          onChange={(gems) => form.setData('gems', gems)}
          placeholder="rails"
          error={form.errors.gems}
        />

        <ListField
          label="mise tools (tool@version)"
          values={form.data.mise ?? []}
          onChange={(mise) => form.setData('mise', mise)}
          placeholder="ruby@3.4"
          error={form.errors.mise}
        />

        <div className="space-y-1">
          <FilesField
            label="Files"
            rows={form.data.files ?? []}
            onChange={(files) => form.setData('files', files)}
            error={form.errors.files}
          />
          <p className="text-sm text-muted-foreground">
            Written into the sandbox at the given absolute path before the harness runs.
          </p>
          {piExtensionError && (
            <p className="text-sm text-muted-foreground">
              Could not generate the pi extension for this provider: {piExtensionError}
            </p>
          )}
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
          Enqueue job
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

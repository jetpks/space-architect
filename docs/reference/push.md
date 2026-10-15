# Push 📦

`architect push` packs the current space into a gzipped tar and ships it to a
space-server's import mouth, so the sink's settled story reaches the server
without a manual rake task on the server host.

## `architect push [SPACE]`

Packs the space (default: `$PWD`, resolved through `space.yaml`) into a
bundle tmpfile, POSTs it to `POST <host>/spaces/import`, and prints the
server's import summary. The bundle tmpfile is deleted when the command ends.

| Option | Default | Description |
|--------|---------|-------------|
| `--host=URL` | — | Base URL of the space-server. Required. |
| `--token=TOKEN` | — | Bearer token for authorization. Required. |

```sh
architect push --host https://spaces.example.com --token $SPACE_TOKEN
architect push 20261014-all-fax-no-printer --host http://localhost:9292 --token tok
```

## The bundle cut

The bundle is streamed — neither the tar nor the packed files are held in
memory. A bundle that ships `repos/`, worktrees, or dependency directories is
a defect; so is one that omits anything the importer reads.

| Excluded | Why |
|----------|-----|
| `repos/` | Full repo clones — hundreds of MB; the server holds its own clones. |
| `build/<id>-<lane>/wt/` | Lane worktrees — checked-out working copies. |
| `tmp/` | Scratch state. |
| `node_modules/` (anywhere) | Dependency trees. |
| `.pi/` | Session/config scratch. |
| `*.log` (anywhere) | Logs, not story. |

| Included (the importer's read set) | Why |
|------------------------------------|-----|
| `space.yaml` | The space's identity. |
| `.git/` | History — iteration timestamps live in commit metadata. |
| `architecture/` | Iteration specs, verdicts, briefs. |
| `notes/` | Durable project notes. |
| `build/<id>-<lane>/prompt.md` | What the builder was asked. |
| `build/<id>-<lane>/report.md` | What the builder reported. |
| `build/<id>-<lane>/run.jsonl` | The run's event stream. |

Everything else in the space is included. Symlinks and other non-regular
files are skipped — the bundle carries regular files and directories only,
so it stays traversal-proof.

## Endpoint contract

`POST <host>/spaces/import`

- Request body: a gzip'd tar stream, `Content-Type: application/gzip`.
- Auth: `Authorization: Bearer <token>`.
- Response `200`: JSON `{id:, slug:, iterations:, artifacts:, runs:}` —
  printed as the command's summary line.
- Failures: `401` (bad token), `400` (bad tar / traversal / missing
  `space.yaml`), `413` (oversize) — the server's error body is surfaced and
  the command exits nonzero.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Packed, pushed, and imported — summary printed. |
| `1` | Missing `--host`/`--token`, packing failure, or any non-200 response (error body on stderr). |

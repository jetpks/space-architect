# space-server

A Ruby/Hanami application for exploring and sharing AI chat transcripts. Upload
a Claude conversation export, browse it with rich markdown and code rendering,
annotate individual turns, and share a read-only link with others.

## Setup

```sh
bundle install
npm install
```

Credentials are managed via Hanami's encrypted credentials store:

```sh
bin/credentials edit   # opens $EDITOR; set github_oauth_id/secret and db url
```

## Run

```sh
bin/dev   # starts web server (:3000), Vite (:3036), and the import worker
```

## Test

```sh
bundle exec rake test  # Ruby suite
npm test               # Vitest (TypeScript/component tests)
npm run check          # TypeScript type check
```

## Ingest Token Auth

Machine pushes (e.g. from the CLI dispatch harness) authenticate via a shared secret:

| Env var          | Description                                      |
|------------------|--------------------------------------------------|
| `INGEST_TOKEN`   | Secret bearer token for `POST /runs` and `POST /runs/:id/ingest` |
| `INGEST_USER_ID` | Integer user ID that ingested runs are owned by  |

When both are set, requests carrying `Authorization: Bearer <INGEST_TOKEN>` are authenticated as the configured user and bypass CSRF (machine pushes carry no session cookie). Browser/cookie requests are unaffected and continue to enforce CSRF normally.

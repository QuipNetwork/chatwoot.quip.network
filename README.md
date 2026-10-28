# chatwoot.quip.network

Chatwoot CE (open-source support inbox: website live chat and an agent
dashboard), packaged as the single-instance Flux app `quipchatwoot` and served at
`support.quip.network`.

Upstream code is unchanged; this repo holds only what it takes to run it on Flux.

| Path | What it is |
|---|---|
| `images/app/` | `chatwoot/chatwoot:v4.19.1-ce` plus baked non-secret config, the `zz_quip.rb` initializer and the start script. Rails and Sidekiq both run it. |
| `images/postgres/` | `pgvector/pgvector:pg16` plus restore-on-empty, a dump loop to Storj, and `dump-now` |
| `deploy/flux/chatwoot-app-spec.json` | Flux spec template. Secrets are `<placeholders>`, and the filled copy is never committed. |
| `deploy/local/` | Local rehearsal behind an FDM-like edge, with no egress |
| `scripts/` | `build-and-push.sh` (the whole release path, no CI) and `lint-spec.py` |

## What the app image changes

- **`config.assume_ssl`.** Flux's domain manager (FDM) terminates TLS and forwards plain HTTP without
  `X-Forwarded-Proto`. Without this, Rails builds the super-admin console's
  redirects and form actions as `http://` URLs, and its CSRF origin check rejects
  every console write with a 422. `FORCE_SSL` stays false, because FDM already
  redirects http to https.
- **No calls to Chatwoot's hub.** Upstream sends the install id, version and
  hostname to `hub.2.chatwoot.com` daily, even with `DISABLE_TELEMETRY`.
- **`DISABLE_GRAVATAR`.** Otherwise contact email hashes are sent to Gravatar.
- **Migrations run before every start.** `db:chatwoot_prepare` migrates an existing schema.
  On an empty database it seeds a fresh install and reopens the public
  onboarding page. That's why Postgres must never come up empty by accident (see below).

## Data across a relocation

Flux gives a relocated single-instance app an empty volume and restores
nothing. Spec updates have come up empty too. So nothing that matters lives only
on the volume:

| State | Lives in | After a relocation |
|---|---|---|
| Conversations, contacts, agents, settings | Postgres, dumped to Storj `chatwoot-db` every 5 min, 48 h kept | Restored from the newest dump before Postgres accepts connections. Up to 5 min can be lost. |
| Attachments, avatars | Storj `chatwoot-uploads` | Untouched |
| Secrets (incl. the Active Record encryption keys) | The encrypted Flux spec, plus Proton Pass "Quip Network Ops-only" | Travel with the spec. Without the same encryption keys, restored 2FA secrets can't be read. |
| Redis (job queue, presence) | Volume | Lost. Accepted. |

**Fail-closed, self-healing.** If a dump exists but can't be restored, Postgres
writes `.restore-failed` on its volume and exits. On every later boot it wipes that
never-restored volume and tries the restore again. It doesn't listen until a
restore succeeds, so rails waits and never seeds an empty database. A Storj outage
during a relocation heals by itself, and so does a bad key once the spec is fixed.
The dump loop never publishes an empty schema.

## Runbook

**Before ANY spec update** (env, repotag, resources):
1. Open Secure Shell on the `postgres` component and run `dump-now`.
2. Expect `published chatwoot-pg/dump-<ts>.dump (<n> bytes)` and exit 0.
3. Anything else means no fresh dump. Don't update.

**After a relocation or redeploy:**
1. In the postgres log, look for `[restore-on-boot] restored chatwoot-pg/dump-<ts>.dump -- <n> tables`.
2. Then check that rails logs `Listening on http://0.0.0.0:3000`.

**Postgres keeps restarting with `a previous restore failed on this volume`:**
1. Read the lines under "what happened". Usually Storj is unreachable, or the key or bucket is wrong.
2. Fix it in the spec if needed. That's a soft update. The next boot retries by itself.
3. Only if the backups are truly gone: set `ALLOW_EMPTY_RESTORE=1` on the
   postgres component. It starts empty and Chatwoot seeds a fresh install, so
   complete onboarding at once. Then remove the variable.

**Upgrade Chatwoot:**
1. Bump the tag and digest in `images/app/Dockerfile`, then `NO_PUSH=1 scripts/build-and-push.sh app`.
2. Rehearse locally (below).
3. `dump-now` on Flux, then `PUSH_ONLY=1 scripts/build-and-push.sh app`.
4. Paste the printed repotag into the rails and sidekiq components. Rails migrates on start.

## Local rehearsal

```sh
NO_PUSH=1 scripts/build-and-push.sh postgres
NO_PUSH=1 scripts/build-and-push.sh app
deploy/local/up.sh                    # https://localhost:8443, mail at :8025, widget page at :8080
docker compose -f deploy/local/compose.yaml down -v   # wipe
```

- Every service except the edge runs on an internal network with no egress. Phone-home
  attempts show up as connection errors in the logs instead of succeeding.
- `QUIP_ASSUME_SSL=false deploy/local/up.sh` reproduces the FDM https trap: the
  console's form actions turn into `http://` URLs and writes return 422.
- **Relocation drill:** `docker compose ... rm -sf fluxpostgres_quipchatwoot`,
  `docker volume rm chatwoot-rehearsal_pgdata`, `up.sh`.

## License

AGPL-3.0, see `LICENSE`. Chatwoot itself is MIT-licensed upstream.

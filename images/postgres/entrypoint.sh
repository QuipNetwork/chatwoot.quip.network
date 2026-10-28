#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Wraps the stock postgres entrypoint: refuses to start after a failed restore,
# then runs the dump loop beside the server.
#
# Why the sentinel check has to live HERE: restore-on-boot.sh runs inside the
# stock entrypoint, after initdb has already written PG_VERSION to the
# persisted volume. Its exit 1 kills the container once; on the restart the
# stock entrypoint sees PG_VERSION, skips init, and serves an empty database.
# So the refusal is recorded as a sentinel on the volume and enforced here,
# before docker-entrypoint.sh can decide the database "already exists".
#
# Escape hatch: a container that refuses to start cannot be shelled into, so it
# is an env var settable from the Flux dashboard. ALLOW_EMPTY_RESTORE=1 clears
# the sentinel and starts on whatever is on the volume. Remove it afterwards.
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

SENTINEL="${PGDATA:-/var/lib/postgresql/data}/.restore-failed"

if [ -e "$SENTINEL" ]; then
    if [ "${ALLOW_EMPTY_RESTORE:-0}" = "1" ]; then
        log "ALLOW_EMPTY_RESTORE=1 -- clearing the failed-restore sentinel and starting anyway."
        log "what tripped it:"
        sed 's/^/[entrypoint]   /' "$SENTINEL" >&2 || true
        rm -f "$SENTINEL"
        log "⚠ REMOVE ALLOW_EMPTY_RESTORE from the spec once this is resolved, or the"
        log "  next failed restore will be cleared silently too."
    else
        log "FATAL: a previous restore attempt failed on this volume and postgres will"
        log "NOT start. Starting would serve an empty database, Chatwoot would seed a"
        log "fresh install and reopen its public onboarding page, and the dump loop"
        log "would then overwrite every good backup with it."
        log ""
        log "what happened:"
        sed 's/^/[entrypoint]   /' "$SENTINEL" >&2 || true
        log ""
        log "Fix the backup store, then redeploy. If the data is genuinely gone and an"
        log "empty database is what you want, set ALLOW_EMPTY_RESTORE=1 on this"
        log "component, start once, then remove it."
        exit 1
    fi
fi

# ⚠ Wait for the TCP listener, NOT the Unix socket. During init the stock
# entrypoint runs a TEMPORARY socket-only server, so a socket probe goes green
# mid-restore and the loop would publish a half-initialised database as newest.
# Backgrounded here so postgres stays this process's exec target.
(
    until pg_isready -q -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" 2>/dev/null; do
        sleep 5
    done
    log "postgres is accepting TCP connections -- starting dump loop"
    exec /usr/local/bin/dump-loop.sh
) &

exec docker-entrypoint.sh "$@"

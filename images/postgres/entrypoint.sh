#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Wraps the stock postgres entrypoint: never serves a volume whose restore
# failed, retries that restore on every boot, then runs the dump loop.
#
# Why the sentinel check has to live HERE: restore-on-boot.sh runs inside the
# stock entrypoint, after initdb has already written PG_VERSION to the
# persisted volume. Its exit 1 kills the container once; on the restart the
# stock entrypoint sees PG_VERSION, skips init, and serves an empty database.
# So the failure is recorded as a sentinel on the volume and acted on here,
# before docker-entrypoint.sh can decide the database "already exists".
#
# The sentinel is only ever written into a cluster the failed restore itself
# initialised, so that cluster holds nothing the bucket does not. Wiping it and
# letting init + restore run again is therefore safe, and it means a restore
# that failed for a passing reason (a Storj outage during a relocation, a key
# fixed by a soft spec update) heals on a later boot instead of needing a hard
# redeploy. FluxOS restarts the container after every failed attempt.
#
# Escape hatch, only for when the backups are genuinely gone: an env var,
# because a container that will not start cannot be shelled into.
# ALLOW_EMPTY_RESTORE=1 clears the sentinel and starts on the EMPTY cluster.
# Chatwoot will then seed a fresh install. Remove it afterwards.
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
        log "a previous restore failed on this volume -- it will NOT be served empty."
        log "what happened:"
        sed 's/^/[entrypoint]   /' "$SENTINEL" >&2 || true
        log "the cluster here was created by that failed attempt and holds nothing the"
        log "bucket does not, so it is wiped and the restore runs again now. Until it"
        log "succeeds postgres does not listen, and Chatwoot waits instead of seeding."
        find "$PGDATA" -mindepth 1 -delete
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

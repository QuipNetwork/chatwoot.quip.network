#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Periodic pg_dump -> S3. Runs beside postgres in the same container, started
# by entrypoint.sh once the server is accepting TCP connections.
#
#   dump-loop.sh          loop forever, one dump per DUMP_INTERVAL_SECONDS
#   dump-loop.sh --once   one verified dump now, exit 0 only if it landed
#                         (what /usr/local/bin/dump-now runs -- take one before
#                         any Flux spec update, which can come up on an empty volume)
#
# Best-effort per iteration: a transient S3 blip must not kill Postgres. The
# fail-closed half of the design lives in restore-on-boot.sh.
set -uo pipefail

log() { printf '[dump-loop] %s\n' "$*" >&2; }

# shellcheck source=lib/s3-snapshot.sh
source /usr/local/lib/s3-snapshot.sh

INTERVAL="${DUMP_INTERVAL_SECONDS:-300}"
PREFIX="${S3_PREFIX:-chatwoot-pg/}"
KEEP="${DUMP_KEEP:-576}"

# Returns 0 only when the dump is published AND HEAD-confirmed.
dump_once() {
    local ts key tmp rc=1
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    key="${PREFIX}dump-${ts}.dump"
    tmp="$(mktemp /tmp/dump.XXXXXX.dump)"

    # An empty schema (first boot, before rails migrates) is never worth a dump,
    # and restore-on-boot refuses one -- publishing it would make the newest
    # dump unrestorable until the next tick replaced it.
    local tables
    tables="$(psql -tAX --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -c "select count(*) from information_schema.tables where table_schema='public';" 2>/dev/null)"
    if ! [ "${tables:-0}" -ge 1 ] 2>/dev/null; then
        log "public schema is empty -- nothing to dump yet"
        rm -f "$tmp"
        return 1
    fi

    if ! pg_dump -Fc --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --file "$tmp"; then
        log "pg_dump failed"
    # Never publish an empty or truncated dump: it would sort newest and become
    # what restore-on-boot picks up after the next relocation.
    elif ! pg_restore --list "$tmp" >/dev/null 2>&1; then
        log "dump failed its own pg_restore --list check -- refusing to publish"
    # s3_put is KEY then FILE.
    elif ! s3_put "$key" "$tmp"; then
        log "upload failed for ${key}"
    # Prune only on a HEAD-confirmed object, or a short upload ages out the last good dump.
    elif ! s3_object_ok "$key"; then
        log "upload reported success but ${key} does not HEAD as non-empty -- NOT pruning"
    else
        log "published ${key} ($(stat -c%s "$tmp") bytes)"
        s3_prune "$PREFIX" "$KEEP" || log "prune failed (non-fatal)"
        rc=0
    fi

    rm -f "$tmp"
    return "$rc"
}

if ! s3_configured; then
    log "S3 not configured -- no dumps will be taken. Postgres data is then only as durable as this Flux volume, which does not survive a relocation."
    [ "${1:-}" = "--once" ] && exit 1
    exit 0
fi

if [ "${1:-}" = "--once" ]; then
    dump_once
    exit $?
fi

log "dumping every ${INTERVAL}s to s3://${S3_BUCKET}/${PREFIX} (keeping ${KEEP})"

# Dump immediately, then sleep: sleeping first leaves the window between deploy
# and the first tick with nothing to restore from.
while :; do
    dump_once || log "retrying next tick"
    sleep "$INTERVAL"
done

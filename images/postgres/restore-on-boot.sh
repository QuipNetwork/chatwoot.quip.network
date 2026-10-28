#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Restore the newest pg_dump from S3 into a freshly-initialised cluster.
#
# The stock postgres entrypoint runs /docker-entrypoint-initdb.d/* only when
# PGDATA was empty, which on Flux means a hard redeploy or a relocation. So this
# script IS the "did we lose the disk" branch.
#
# FAIL-CLOSED, and it matters more for Chatwoot than for most apps: if Postgres
# came up empty, rails' db:chatwoot_prepare would load the schema, seed, and
# REOPEN the public onboarding page -- the first visitor becomes super admin --
# and the next dump would overwrite the good backups with the empty install.
#
# ⚠ Exiting non-zero is not enough on its own. initdb has already written
# PG_VERSION, so the restart skips this directory and serves an empty database.
# Every failure path therefore drops a sentinel on the persisted volume, and
# entrypoint.sh wipes that volume and retries the restore on the next boot.
set -Eeuo pipefail

log() { printf '[restore-on-boot] %s\n' "$*" >&2; }

SENTINEL="${PGDATA:?PGDATA is unset}/.restore-failed"
PREFIX="${S3_PREFIX:-chatwoot-pg/}"

# Record why we refused, so every later boot attempt prints it.
mark_failed() {
    {
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) restore failed: ${1:-unexpected error}"
        echo "  bucket=${S3_BUCKET:-<unset>} prefix=${PREFIX} endpoint=${S3_ENDPOINT:-<unset>}"
    } >>"$SENTINEL" 2>/dev/null || true
}

# set -E carries this into functions and subshells, so a failure nobody
# anticipated below still marks the volume.
trap 'mark_failed "unhandled error at line $LINENO"' ERR

die() { log "FATAL: $*"; mark_failed "$*"; exit 1; }

# shellcheck source=lib/s3-snapshot.sh
source /usr/local/lib/s3-snapshot.sh

if ! s3_configured; then
    # Partly configured is a broken spec edit, not a first deploy.
    if [ -n "${S3_ENDPOINT:-}${S3_BUCKET:-}${S3_ACCESS_KEY:-}${S3_SECRET_KEY:-}" ]; then
        die "S3 is partly configured (need all of S3_ENDPOINT, S3_BUCKET, S3_ACCESS_KEY, S3_SECRET_KEY)"
    fi
    log "S3 not configured (S3_ENDPOINT/S3_BUCKET/S3_ACCESS_KEY/S3_SECRET_KEY) -- starting empty."
    log "This is correct ONLY for a first-ever deploy. If this instance previously had data, stop now."
    exit 0
fi

# ⚠ Bound every S3 call. This runs inside the postgres entrypoint's init phase,
# so a hang here wedges the container mid-init instead of failing it.
export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=3
S3_CALL_TIMEOUT="${S3_CALL_TIMEOUT:-120}"

# Keys are <prefix>dump-<utc-ts>.dump, so "newest" is a lexical sort.
# s3_list is a shell function, so `timeout` needs a fresh shell to call it in.
keys="$(timeout "$S3_CALL_TIMEOUT" bash -c '
    source /usr/local/lib/s3-snapshot.sh
    s3_list "$1"
' _ "$PREFIX")" || {
    rc=$?
    if [ "$rc" -eq 124 ]; then
        die "listing s3://${S3_BUCKET}/${PREFIX} timed out after ${S3_CALL_TIMEOUT}s"
    fi
    die "could not list s3://${S3_BUCKET}/${PREFIX} (rc=${rc}) -- a failed listing is not an empty bucket"
}

newest="$(printf '%s\n' "$keys" | grep -E 'dump-.*\.dump$' | sort | tail -1 || true)"

if [ -z "$newest" ]; then
    log "no dump under s3://${S3_BUCKET}/${PREFIX} (the listing itself succeeded) -- first-ever deploy, starting empty."
    exit 0
fi

log "restoring newest dump: ${newest}"
tmp="$(mktemp /tmp/restore.XXXXXX.dump)"
trap 'rm -f "$tmp"' EXIT

timeout "$S3_CALL_TIMEOUT" bash -c '
    source /usr/local/lib/s3-snapshot.sh
    s3_get "$1" "$2"
' _ "$newest" "$tmp" || die "download failed for ${newest}"
[ -s "$tmp" ] || die "downloaded dump is empty: ${newest}"

# --exit-on-error so a partial restore is a failure, not a warning.
pg_restore \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    --no-owner --no-privileges \
    --exit-on-error \
    "$tmp" || die "pg_restore failed for ${newest}"

tables="$(psql -tAX --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -c "select count(*) from information_schema.tables where table_schema='public';")"

# Assert the positive: a dump of an empty database restores cleanly too.
[ "${tables:-0}" -ge 1 ] || die "restore reported success but public schema has ${tables:-0} tables"

log "restored ${newest} -- ${tables} tables in public schema."

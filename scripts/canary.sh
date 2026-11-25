#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Canary: does Chatwoot's newest CE release still build with our overlay and
# boot the way the quipchatwoot Flux app runs it? Pushes NOTHING.
#
#   scripts/canary.sh                          # newest upstream release
#   CANARY_VERSION=v4.21.0 scripts/canary.sh   # a specific one
#   scripts/canary.sh --down                   # remove the rehearsal stack
#
# Runs weekly in CI (.gitlab-ci.yml) and works the same on a workstation.
#   1. Ask GitHub for the newest release; use its chatwoot/chatwoot:<tag>-ce.
#   2. Point images/app/Dockerfile at it in THIS checkout only, and build with
#      NO_PUSH -- build-and-push.sh's own asserts and Ruby tests run.
#   3. Boot deploy/local (the Flux-faithful rehearsal: Flux service names,
#      Flux memory limits, a backend network with no egress) with that app
#      image and the postgres + redis images the deployed spec pins.
#   4. From inside the stack, check rails' /api: it reports the new version,
#      and its queue (redis) and data (postgres) services are ok. Check
#      sidekiq is up and stays up.
# A boot on an empty database proves the release starts and migrates from
# scratch; it says nothing about migrating our real data. That is still the
# upgrade's own rehearsal (README: Upgrade Chatwoot).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DC=(docker compose -f deploy/local/compose.yaml)
log() { echo "==> $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

if [ "${1:-}" = "--down" ]; then
    # compose refuses to parse the file without the rehearsal secrets, so only
    # tear down a stack that up.sh actually started.
    [ -s deploy/local/.env ] || { log "no rehearsal .env -- nothing to remove"; exit 0; }
    "${DC[@]}" down -v --remove-orphans
    exit 0
fi

# 1. Newest upstream release.
if [ -z "${CANARY_VERSION:-}" ]; then
    CANARY_VERSION="$(curl -fsS --max-time 20 -A chatwoot-canary -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/chatwoot/chatwoot/releases/latest \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')" \
        || die "could not read chatwoot/chatwoot's latest release from GitHub"
fi
[[ "$CANARY_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected release tag '${CANARY_VERSION}'"
BASE="chatwoot/chatwoot:${CANARY_VERSION}-ce"
PINNED="$(sed -n 's|^FROM \(chatwoot/chatwoot:[^@ ]*\).*|\1|p' images/app/Dockerfile)"
[ -n "$PINNED" ] || die "no 'FROM chatwoot/chatwoot:' line in images/app/Dockerfile"
log "newest upstream: ${BASE}   deployed pin: ${PINNED}"

# 2. Build our overlay on it. The Dockerfile edit stays in this checkout; CI
# throws the checkout away, and on a workstation `git checkout images/app` undoes it.
sed -i "s|^FROM chatwoot/chatwoot:[^ ]*|FROM ${BASE}|" images/app/Dockerfile
grep -qxF "FROM ${BASE}" images/app/Dockerfile || die "could not point images/app/Dockerfile at ${BASE}"
TAG="app-${CANARY_VERSION}-ce-canary-amd64"
NO_PUSH=1 TAG="$TAG" scripts/build-and-push.sh app
APP_IMAGE="registry.gitlab.com/quip.network/chatwoot.quip.network:${TAG}"

# 3. Boot it next to what is deployed.
read -r PG_IMAGE REDIS_IMAGE < <(python3 - <<'PY'
import json
spec = json.load(open("deploy/flux/chatwoot-app-spec.json"))
tags = {c["name"]: c["repotag"] for c in spec["compose"]}
print(tags["postgres"], tags["redis"])
PY
)
[ -n "${PG_IMAGE:-}" ] && [ -n "${REDIS_IMAGE:-}" ] || die "could not read the postgres/redis repotags from the spec"
APP_IMAGE="$APP_IMAGE" PG_IMAGE="$PG_IMAGE" REDIS_IMAGE="$REDIS_IMAGE" deploy/local/up.sh

ctr() { "${DC[@]}" ps -q "$1"; }
state() { docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$(ctr "$1")" 2>/dev/null || echo "missing -"; }

# 4. Rails answers /api from inside its own container (the edge's ports are
# loopback-only on whatever host runs the daemon, so don't go through them).
log "waiting for rails /api (first boot runs db:chatwoot_prepare on an empty database)"
deadline=$((SECONDS + 900)) api=""
while :; do
    api="$("${DC[@]}" exec -T fluxrails_quipchatwoot ruby -rnet/http -e \
        'print Net::HTTP.get(URI("http://127.0.0.1:3000/api"))' 2>/dev/null)" && [ -n "$api" ] && break
    if [ "$SECONDS" -gt "$deadline" ]; then
        "${DC[@]}" logs --tail 60 fluxrails_quipchatwoot || true
        die "rails did not answer /api within 15 minutes (state: $(state fluxrails_quipchatwoot))"
    fi
    sleep 10
done

WANT="${CANARY_VERSION#v}"
API="$api" WANT="$WANT" python3 - <<'PY' || die "rails /api check failed"
import json, os, sys
try:
    d = json.loads(os.environ["API"])
except ValueError:
    sys.exit(f"  FAIL  /api did not return JSON: {os.environ['API'][:200]!r}")
want, bad = os.environ["WANT"], []
checks = [("version", want), ("queue_services", "ok"), ("data_services", "ok")]
for key, expect in checks:
    ok = str(d.get(key)) == expect
    print(f"  {'PASS' if ok else 'FAIL'}  /api {key} = {d.get(key)!r} (want {expect!r})")
    bad += [] if ok else [key]
sys.exit(1 if bad else 0)
PY

# Sidekiq may restart while rails is still migrating; it must be running now
# and still running, with no new restarts, a minute later.
s1="$(state fluxsidekiq_quipchatwoot)"; sleep 60; s2="$(state fluxsidekiq_quipchatwoot)"
[ "${s1%% *}" = running ] && [ "$s1" = "$s2" ] \
    || { "${DC[@]}" logs --tail 40 fluxsidekiq_quipchatwoot || true; die "sidekiq not stable: '${s1}' then '${s2}' (status restarts)"; }
echo "  PASS  sidekiq running, restart count steady at ${s2#* }"
echo "  info  rails restarts during boot: $(state fluxrails_quipchatwoot | cut -d' ' -f2)"

log "canary PASSED: Chatwoot ${CANARY_VERSION} on our overlay boots against the deployed postgres + redis"

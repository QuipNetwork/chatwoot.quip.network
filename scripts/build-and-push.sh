#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build (and optionally push) one of this repo's images, check it, then print
# the exact repotag for deploy/flux/chatwoot-app-spec.json.
#
#   scripts/build-and-push.sh app|postgres                 # build + check + push
#   NO_PUSH=1   scripts/build-and-push.sh app|postgres     # build + check only
#   PUSH_ONLY=1 scripts/build-and-push.sh app|postgres     # push the tag NO_PUSH built
#
# This repo has NO CI, so this is the whole release path.
#
# ⚠ Test the NO_PUSH image, then push THAT tag with PUSH_ONLY. With the
# containerd image store every build makes a new image ID, even fully cached,
# so a rebuild ships something you have not tested.
# ⚠ amd64 ONLY, and --provenance/--sbom off: Flux wants a plain single-arch
# image it can pin by digest.
#
# Requires for push: docker login registry.gitlab.com (PAT with write_registry).
set -euo pipefail

NAME="${1:?usage: build-and-push.sh app|postgres}"
REGISTRY="${REGISTRY:-registry.gitlab.com}"
REPO="${REPO:-quip.network/chatwoot.quip.network}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

case "$NAME" in
    app)      PREFIX="app-v4.19.1-ce" ;;
    postgres) PREFIX="pg16" ;;
    *) echo "FATAL: unknown image '${NAME}' (app|postgres)" >&2; exit 1 ;;
esac

SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nohead)"
DIRTY=""
git diff --quiet HEAD -- "images/${NAME}" images/trust-store 2>/dev/null || DIRTY="-dirty"
TAG="${TAG:-${PREFIX}-${SHA}${DIRTY}-amd64}"
IMAGE="${REGISTRY}/${REPO}:${TAG}"

[ -z "$DIRTY" ] || echo "⚠ images/${NAME} is dirty or uncommitted -- tagging '${TAG}'. Commit before a real release." >&2

if [ -n "${PUSH_ONLY:-}" ]; then
    docker image inspect "$IMAGE" >/dev/null 2>&1 \
        || { echo "FATAL: PUSH_ONLY set but ${IMAGE} is not built locally" >&2; exit 1; }
    echo "==> PUSH_ONLY set -- re-checking the local ${IMAGE}, not rebuilding"
else
    echo "==> building ${IMAGE}"
    docker build \
        --platform linux/amd64 \
        --provenance=false \
        --sbom=false \
        --build-context trust-store=images/trust-store \
        -t "$IMAGE" \
        "images/${NAME}"
fi

arch="$(docker image inspect "$IMAGE" --format '{{.Architecture}}/{{.Os}}')"
[ "$arch" = "amd64/linux" ] || { echo "FATAL: built ${arch}, expected amd64/linux" >&2; exit 1; }

# Assert the properties the Flux spec and the restore path depend on.
case "$NAME" in
postgres)
    docker run --rm --entrypoint sh "$IMAGE" -c '
        set -e
        [ "$PGDATA" = "/var/lib/postgresql/data" ] || { echo "FATAL: PGDATA=$PGDATA (spec mounts /var/lib/postgresql/data)"; exit 1; }
        [ -x /docker-entrypoint-initdb.d/10-restore-on-boot.sh ] || { echo "FATAL: restore hook missing"; exit 1; }
        [ -x /usr/local/bin/dump-loop.sh ] && [ -x /usr/local/bin/dump-now ] || { echo "FATAL: dump scripts missing"; exit 1; }
        command -v aws >/dev/null || { echo "FATAL: awscli missing"; exit 1; }
        [ "$AWS_CA_BUNDLE" = "/etc/ssl/certs/ca-certificates.crt" ] || { echo "FATAL: AWS_CA_BUNDLE=$AWS_CA_BUNDLE"; exit 1; }
        [ -f /usr/share/postgresql/16/extension/vector.control ] || { echo "FATAL: pgvector missing"; exit 1; }
    '
    echo "    ok: amd64, PGDATA, restore hook, dump-loop + dump-now, awscli, AWS_CA_BUNDLE, pgvector"
    ;;
app)
    # A secret baked into a public image is published the moment it is pushed.
    leaked="$(docker image inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' \
        | grep -E '^(SECRET_KEY_BASE|ACTIVE_RECORD_ENCRYPTION_[A-Z_]+|POSTGRES_PASSWORD|REDIS_PASSWORD|SMTP_PASSWORD|STORAGE_ACCESS_KEY_ID|STORAGE_SECRET_ACCESS_KEY)=' || true)"
    [ -z "$leaked" ] || { echo "FATAL: secret variables baked into the image:" >&2; echo "$leaked" | cut -d= -f1 >&2; exit 1; }
    docker run --rm --entrypoint sh "$IMAGE" -c '
        set -e
        [ -f /app/config/initializers/zz_quip.rb ] || { echo "FATAL: zz_quip.rb missing"; exit 1; }
        [ -x /usr/local/bin/quip-rails-start.sh ] || { echo "FATAL: start script missing"; exit 1; }
        [ -x /app/docker/entrypoints/rails.sh ] || { echo "FATAL: upstream entrypoint moved"; exit 1; }
        [ "$QUIP_ASSUME_SSL" = "true" ] && [ "$FORCE_SSL" = "false" ] || { echo "FATAL: TLS flags wrong"; exit 1; }
    '
    echo "    ok: amd64, no secrets in Config.Env, initializer + start script + upstream entrypoint present"
    ;;
esac

if [ -n "${NO_PUSH:-}" ]; then
    echo "==> NO_PUSH set -- stopping before push"
    exit 0
fi

echo "==> pushing"
docker push "$IMAGE"

# ⚠ Read the digest back FROM THE REGISTRY: `docker image inspect .Id` differs
# by image store. And don't trust `imagetools inspect --format`, which some
# buildx versions ignore -- parse the report and assert the shape.
DIGEST="$(docker buildx imagetools inspect "$IMAGE" | awk '/^Digest:/{print $2; exit}')"
case "$DIGEST" in
    sha256:????????????????????????????????????????????????????????????????) ;;
    *) echo "FATAL: could not read a sha256 manifest digest (got: '${DIGEST}')" >&2; exit 1 ;;
esac

# The spec sets repoauth="" -- verify anyone can pull it rather than assume.
anon="$(curl -fsS "https://gitlab.com/jwt/auth?service=container_registry&scope=repository:${REPO}:pull" \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${anon}" \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "https://${REGISTRY}/v2/${REPO}/manifests/${DIGEST}")"
if [ "$code" = "200" ]; then
    echo "    ok: anonymous pull by digest returns 200 -- repoauth can stay empty"
else
    echo "⚠ WARNING: anonymous pull by digest returned ${code}, not 200 -- a spec with repoauth=\"\" will fail to deploy." >&2
fi

echo
echo "repotag for deploy/flux/chatwoot-app-spec.json (${NAME}):"
echo
echo "  ${IMAGE}@${DIGEST}"
echo
echo "(tag AND digest, both -- Flux rejects a bare repo@sha256: form)"

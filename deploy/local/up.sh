#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Start the local rehearsal of the quipchatwoot Flux app.
#
#   deploy/local/up.sh                         # newest locally built images
#   APP_IMAGE=... PG_IMAGE=... deploy/local/up.sh
#   QUIP_ASSUME_SSL=false deploy/local/up.sh   # control arm: expect the FDM 422
#
# Then: https://localhost:8443 (accept the self-signed cert), the widget page at
# http://127.0.0.1:8080/?token=<inbox token>, mail at http://127.0.0.1:8025.
# Wipe everything: docker compose -f deploy/local/compose.yaml down -v
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_IMG="registry.gitlab.com/quip.network/chatwoot.quip.network"
cd "$HERE"

newest() {
    docker images "$REPO_IMG" --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}' \
        | grep -F ":$1-" | sort -r | head -1 | cut -f2
}
APP_IMAGE="${APP_IMAGE:-$(newest app)}"
PG_IMAGE="${PG_IMAGE:-$(newest pg16)}"
[ -n "$APP_IMAGE" ] && [ -n "$PG_IMAGE" ] \
    || { echo "FATAL: build first: NO_PUSH=1 scripts/build-and-push.sh app|postgres" >&2; exit 1; }
export APP_IMAGE PG_IMAGE

# Rehearsal secrets: random, local, gitignored, stable across restarts so the
# relocation drill restores into the same keys -- exactly as on Flux.
if [ ! -s .env ]; then
    (umask 077
    {
        echo "SECRET_KEY_BASE=$(openssl rand -hex 64)"
        echo "AR_PRIMARY_KEY=$(openssl rand -hex 16)"
        echo "AR_DETERMINISTIC_KEY=$(openssl rand -hex 16)"
        echo "AR_KEY_DERIVATION_SALT=$(openssl rand -hex 16)"
        echo "PG_PASSWORD=$(openssl rand -hex 24)"
        echo "REDIS_PASSWORD=$(openssl rand -hex 24)"
        echo "MINIO_USER=rehearsal"
        echo "MINIO_PASSWORD=$(openssl rand -hex 24)"
    } > .env)
    echo "==> wrote rehearsal secrets to deploy/local/.env"
fi

if [ ! -s certs/edge.pem ]; then
    mkdir -p certs
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        -keyout certs/edge.key -out certs/edge.crt 2>/dev/null
    cat certs/edge.crt certs/edge.key > certs/edge.pem
    # haproxy runs as a non-root user; this throwaway key guards nothing.
    chmod 755 certs && chmod 644 certs/edge.pem
    echo "==> wrote a self-signed localhost cert to deploy/local/certs/"
fi

# Record the images in .env too, so plain `docker compose logs|ps|down` work.
sed -i -e '/^APP_IMAGE=/d' -e '/^PG_IMAGE=/d' .env
printf 'APP_IMAGE=%s\nPG_IMAGE=%s\n' "$APP_IMAGE" "$PG_IMAGE" >> .env

echo "==> app:      ${APP_IMAGE}"
echo "==> postgres: ${PG_IMAGE}"
echo "==> QUIP_ASSUME_SSL=${QUIP_ASSUME_SSL:-true}  FDM_TIMEOUT=${FDM_TIMEOUT:-25s}"
docker compose -f compose.yaml up -d "$@"
echo
echo "Chatwoot:     https://localhost:8443"
echo "Widget page:  http://127.0.0.1:8080/?token=<website inbox token>"
echo "Mail:         http://127.0.0.1:8025"

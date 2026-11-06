# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Redis for Chatwoot on Flux: stock redis, served from our own registry.
#
# ⚠ Why this image exists at all: every 6 hours FluxOS's image updater
# (imageUpdateService.js) compares each component's TAG on the registry with
# the image the node runs. It ignores the @sha256 pin in the repotag. Docker Hub
# moves `redis:7.4-alpine` whenever it rebuilds, so a spec pinning
# redis:7.4-alpine@sha256:... got the whole app soft-redeployed (all four
# containers removed, images re-pulled, ~3 min down) every 6 hours (QUI-2170).
# Our tags are written once and never move, so the check always matches.
#
# The digest below is the one the app ran on before this image existed, so only
# where the image comes from changed. To upgrade redis, bump it here and rebuild.
FROM redis:7.4-alpine@sha256:6ba19c50b56777f5c11c58eff8ddb69d0d5f27ba131cffb63f180ccfd43c66af

# The labels give this image its own ID. Otherwise a node still holding the
# Docker Hub image could list that digest first in RepoDigests, which is the
# entry the updater compares.
LABEL org.opencontainers.image.source="https://gitlab.com/quip.network/chatwoot.quip.network" \
      org.opencontainers.image.base.name="redis:7.4-alpine@sha256:6ba19c50b56777f5c11c58eff8ddb69d0d5f27ba131cffb63f180ccfd43c66af"

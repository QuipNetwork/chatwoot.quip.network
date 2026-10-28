#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The rails component's command. Flux has no run-once step, so the migration
# upstream runs by hand (`docker compose run --rm rails ... db:chatwoot_prepare`)
# runs here, before every server start. It is idempotent: it migrates an
# existing schema and only loads + seeds when the database has none.
#
# ⚠ That second branch is why postgres must never come up empty after a
# relocation: seeding reopens the public onboarding page. The postgres image's
# restore sentinel keeps it down instead, and docker/entrypoints/rails.sh waits
# on pg_isready, so this never runs against an unrestored volume.
set -e

# Upstream's Heroku release phase raises the 14 s default for long migrations.
POSTGRES_STATEMENT_TIMEOUT=600s bundle exec rails db:chatwoot_prepare

exec bundle exec rails s -b 0.0.0.0 -p 3000

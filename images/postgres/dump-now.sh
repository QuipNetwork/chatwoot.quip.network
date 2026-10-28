#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# One verified dump to S3, now. Run from the Flux Secure Shell before ANY spec
# update -- on this single-instance app an update can come up on an empty
# volume, and the restore can only be as fresh as the newest dump.
#
#   dump-now    -> "[dump-loop] published chatwoot-pg/dump-<ts>.dump (<n> bytes)", exit 0
#
# Anything else, or a non-zero exit, means no new dump landed: do not update.
exec /usr/local/bin/dump-loop.sh --once

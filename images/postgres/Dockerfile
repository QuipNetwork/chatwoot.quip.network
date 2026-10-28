# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Postgres for Chatwoot on Flux.
#
# pg16 + pgvector matches upstream's docker-compose.production.yaml; the schema
# enables vector, pg_trgm, pgcrypto and pg_stat_statements.
#
# What this adds over stock is durability, forced by Flux: at instances:1 a
# relocation hands the app a freshly formatted volume and nothing in FluxOS
# restores it. So Postgres here is a cache of an off-box dump: restore-on-boot
# into a fresh volume, a verified pg_dump to S3 (Storj) every few minutes, and a
# sentinel that keeps a failed restore failed. The scripts come from
# feedback.quip.network (restore, dump loop, s3-snapshot.sh) and
# observe.quip.network (the sentinel).
#
# ⚠ Mount the Flux volume at /var/lib/postgresql/data, the image's own VOLUME
# path. Mounting the parent leaves an anonymous Docker volume over PGDATA and
# the data never reaches the Flux volume at all.
FROM pgvector/pgvector:pg16@sha256:7b822b0aac60967beb1ea5e576b8602c94c300a157d187f385ae3e0da199b90a

# ⚠ This container holds the Storj database key, so its trust store must not
# accept the forged eMudhra chain (QUI-1923). The fixed ca-certificates comes
# from bookworm-security, which the base already lists; the assert refuses the
# build if either root survives. Debian's awscli verifies with botocore's own
# cacert.pem, so AWS_CA_BUNDLE points it at the fixed OS bundle.
COPY --from=trust-store assert-fixed-bundle.sh /tmp/assert-fixed-bundle.sh
RUN apt-get update \
    && apt-get install -y --no-install-recommends awscli ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sh /tmp/assert-fixed-bundle.sh /etc/ssl/certs/ca-certificates.crt \
    && rm /tmp/assert-fixed-bundle.sh
ENV AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# Vendored BYTE-IDENTICAL from bootnodes.quip.network/lib/ (via
# feedback.quip.network). Functions only. Do not trim it.
COPY lib/s3-snapshot.sh /usr/local/lib/s3-snapshot.sh

# Runs ONLY when PGDATA is empty, against a temporary socket-only server, so the
# restore lands before any client can connect.
COPY restore-on-boot.sh /docker-entrypoint-initdb.d/10-restore-on-boot.sh

COPY dump-loop.sh /usr/local/bin/dump-loop.sh
COPY dump-now.sh /usr/local/bin/dump-now
COPY entrypoint.sh /usr/local/bin/quip-entrypoint.sh
RUN chmod +x /docker-entrypoint-initdb.d/10-restore-on-boot.sh \
             /usr/local/bin/dump-loop.sh \
             /usr/local/bin/dump-now \
             /usr/local/bin/quip-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/quip-entrypoint.sh"]
# ⚠ Not redundant: declaring ENTRYPOINT resets the inherited CMD to empty.
CMD ["postgres"]

# POSTGRES_* and S3_* come from the Flux spec. Never bake them.

# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Chatwoot CE for the quipchatwoot Flux app: the rails and sidekiq components
# both run this image (sidekiq overrides the command in the Flux spec).
#
# Everything non-secret is baked here so it does not spend Flux
# environmentParameters slots (hard cap: 20 per component). Secrets come from
# the spec at runtime and must never appear in a layer:
#   SECRET_KEY_BASE, ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY,
#   ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY,
#   ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT, POSTGRES_PASSWORD,
#   REDIS_PASSWORD, SMTP_PASSWORD, STORAGE_ACCESS_KEY_ID,
#   STORAGE_SECRET_ACCESS_KEY
FROM chatwoot/chatwoot:v4.19.1-ce@sha256:04895c7bd0550d9e74b45b7202787b56f7ee4e891ebbde0c429c8c32901b97cf

# ⚠ This container holds the Storj uploads key and the Proton SMTP token, so
# its trust store must not accept the forged eMudhra chain (QUI-1923). The
# base ships ca-certificates-bundle 20241121, so upgrade it and let the assert
# refuse the build if either root survives.
COPY --from=trust-store assert-fixed-bundle.sh /tmp/assert-fixed-bundle.sh
RUN apk add --no-cache --upgrade ca-certificates-bundle \
    && sh /tmp/assert-fixed-bundle.sh /etc/ssl/certs/ca-certificates.crt \
    && rm /tmp/assert-fixed-bundle.sh

# Hostnames are Flux's inter-component names, flux<component>_<app>.
ENV NODE_ENV=production \
    RAILS_ENV=production \
    INSTALLATION_ENV=docker \
    FRONTEND_URL=https://support.quip.network \
    ENABLE_ACCOUNT_SIGNUP=false \
    FORCE_SSL=false \
    QUIP_ASSUME_SSL=true \
    DISABLE_TELEMETRY=true \
    DISABLE_GRAVATAR=true \
    ENABLE_PUSH_RELAY_SERVER=false \
    POSTGRES_HOST=fluxpostgres_quipchatwoot \
    POSTGRES_PORT=5432 \
    POSTGRES_USERNAME=chatwoot \
    POSTGRES_DATABASE=chatwoot \
    REDIS_URL=redis://fluxredis_quipchatwoot:6379 \
    MAILER_SENDER_EMAIL="Quip Support <no-reply@quip.network>" \
    SMTP_ADDRESS=smtp.protonmail.ch \
    SMTP_PORT=587 \
    SMTP_DOMAIN=quip.network \
    SMTP_USERNAME=no-reply@quip.network \
    SMTP_AUTHENTICATION=login \
    SMTP_ENABLE_STARTTLS_AUTO=true \
    SMTP_OPENSSL_VERIFY_MODE=peer \
    ACTIVE_STORAGE_SERVICE=s3_compatible \
    STORAGE_BUCKET_NAME=chatwoot-uploads \
    STORAGE_REGION=us-east-1 \
    STORAGE_ENDPOINT=https://gateway.storjshare.io \
    STORAGE_FORCE_PATH_STYLE=true \
    VIPS_BLOCK_UNTRUSTED=1 \
    RAILS_LOG_TO_STDOUT=true \
    LOG_LEVEL=info

COPY zz_quip.rb /app/config/initializers/zz_quip.rb
COPY quip-rails-start.sh /usr/local/bin/quip-rails-start.sh
RUN chmod +x /usr/local/bin/quip-rails-start.sh

# Upstream's entrypoint clears stale pids and waits for postgres over TCP.
ENTRYPOINT ["/app/docker/entrypoints/rails.sh"]
CMD ["/usr/local/bin/quip-rails-start.sh"]
EXPOSE 3000

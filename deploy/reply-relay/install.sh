#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Install or refresh the reply.quip.network receiver on the developers-portal
# droplet (Debian 13). Run as root from this folder. Safe to run again.
#
# Not done here, on purpose:
#   * the relay password: /etc/chatwoot-relay/curl-auth.conf (see README.md)
#   * DNS (MX reply.quip.network -> mx.reply.quip.network) and the DO firewall
#     rule for TCP 25; both live outside the box
set -eu
cd "$(dirname "$0")"

id chatwoot-relay >/dev/null 2>&1 ||
    useradd --system --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin chatwoot-relay

if ! dpkg -s postfix >/dev/null 2>&1; then
    # Installing postfix removes exim4 (Debian's default local-only MTA).
    echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y postfix postfix-pcre
fi

install -d -m 0750 -o root -g chatwoot-relay /etc/chatwoot-relay
install -m 0755 chatwoot-relay /usr/local/bin/chatwoot-relay
install -m 0644 main.cf /etc/postfix/main.cf
install -m 0644 chatwoot-recipients.pcre chatwoot-transport /etc/postfix/
grep -q '^chatwoot ' /etc/postfix/master.cf || cat master.cf.append >> /etc/postfix/master.cf

newaliases
postfix check
systemctl enable --quiet postfix
systemctl restart postfix
echo "postfix $(postconf -h mail_version) up; relay password present: $(test -s /etc/chatwoot-relay/curl-auth.conf && echo yes || echo NO)"

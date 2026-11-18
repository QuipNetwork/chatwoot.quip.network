# reply.quip.network: email replies into Chatwoot

Chatwoot sends support mail with `Reply-To: reply+<conversation-uuid>@reply.quip.network`.
When a user replies, this receiver takes the mail and hands it to Chatwoot's
built-in relay ingress at `https://desk.quip.network/rails/action_mailbox/relay/inbound_emails`.
Chatwoot then files it in the conversation that the uuid names.

Chatwoot runs on Flux. Flux only passes web traffic to it, and its IP changes
when Flux moves it, so it can't be an MX itself. The receiver runs on the
`developers-portal` droplet (45.55.180.147, Debian 13), which has a fixed IP.
No mail company sees support mail.

## What's outside the box

- DNS (DNSimple):
  - `mx.reply.quip.network` A `45.55.180.147`, AAAA `2604:a880:800:14:0:3:ceb5:2000`
  - `reply.quip.network` MX 10 `mx.reply.quip.network`
  - `reply.quip.network` TXT `v=spf1 -all` (this domain never sends)
- DO Cloud Firewall `developers-portal`: inbound TCP 25 from anywhere.
- Chatwoot (Flux spec, rails only): `RAILS_INBOUND_EMAIL_SERVICE=relay` and
  `RAILS_INBOUND_EMAIL_PASSWORD`. Without the password, the ingress answers 401.
  With another ingress selected, it answers 404.
- Chatwoot settings: Super Admin → App Config → `MAILER_INBOUND_EMAIL_DOMAIN=reply.quip.network`,
  the account's inbound email feature, and email continuity on each inbox.
  These turn the reply+ Reply-To on. Turn them on only once this receiver works,
  or users' replies bounce.

## Install

As root on the droplet, from a copy of this folder:

```sh
sh install.sh
```

The relay password is the same value as `RAILS_INBOUND_EMAIL_PASSWORD` (Proton Pass:
"chatwoot inbound relay password (QUI-2142)"). Put it on the box by hand. It
never goes into this repo, into argv or into the script:

```sh
read -rsp 'relay password: ' PW; echo
printf 'user = "actionmailbox:%s"\n' "$PW" |
    install -m 0640 -o root -g chatwoot-relay /dev/stdin /etc/chatwoot-relay/curl-auth.conf
unset PW
```

## How it behaves

- **Accepted:** only `reply+<uuid>@reply.quip.network`. Every other recipient is
  refused during the SMTP handshake, so no bounce is ever sent. The box can't
  send mail anyway: DO blocks outbound 25.
- **Size:** messages are capped at 25 MB.
- **TLS:** offered on receive, with Debian's self-signed snakeoil cert.
- **Delivery:** each accepted mail runs `/usr/local/bin/chatwoot-relay` once, as
  user `chatwoot-relay`. A 2xx from Chatwoot means the mail is delivered. Anything
  else (Chatwoot down, Flux moving it, wrong password, missing password file)
  exits 75, and Postfix keeps the mail and retries for up to 5 days.
- **Logs:** `journalctl -t postfix/pipe -t postfix/smtpd` (a deferral carries the `chatwoot-relay:` reason).
- **Queue:** `postqueue -p`.

## Checks

```sh
# the recipient rule
postmap -q 'reply+0b1e2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d@reply.quip.network' pcre:/etc/postfix/chatwoot-recipients.pcre   # OK
postmap -q 'support@reply.quip.network' pcre:/etc/postfix/chatwoot-recipients.pcre                                     # (nothing)
# a local test delivery all the way to Chatwoot (an unknown uuid is accepted, then dropped by Chatwoot)
printf 'From: test@example.com\nTo: reply+00000000-0000-4000-8000-000000000000@reply.quip.network\nSubject: relay test\n\nhello\n' |
    sendmail -f test@example.com reply+00000000-0000-4000-8000-000000000000@reply.quip.network
journalctl -t postfix/pipe -n 5 --no-pager    # expect status=sent, relay=chatwoot
```

# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The trimmed-reply patch against the real Chatwoot classes: the image's own
# MailPresenter, EmailReplyTrimmer and ReplyMailbox, through zz_quip.rb's
# prepend. Needs Rails booted but no database. From the repo root:
#   docker run --rm --network none -e SECRET_KEY_BASE=check \
#     -v "$PWD/images/app/test:/q:ro" --entrypoint sh <app image> \
#     -c 'cd /app && bundle exec rails runner /q/quip_email_reply_check.rb'
# Prints "quip_email_reply check: ok" last, or raises.

# A Proton Mail reply, shaped like the ones in desk conversation 93 (text and
# HTML parts, signature block, protonmail_quote), with made-up words.
PROTON = <<~MAIL.freeze
  From: Test User <user@example.com>
  To: reply+fffa5ed9-0000-4000-8000-000000000000@reply.quip.network
  Subject: Re: Your ticket
  Message-ID: <quip-check-1@example.com>
  MIME-Version: 1.0
  Content-Type: multipart/alternative; boundary="b1"

  --b1
  Content-Type: text/plain; charset=utf-8

  Still broken after the update.

  Sent with Proton Mail secure email.

  On Wednesday, November 25th, 2026 at 2:30 PM, Quip Support <no-reply-chatwoot@quip.network> wrote:

  > Thanks for the report. Can you try again after the update?
  >
  > > It crashes when I open the wallet.

  --b1
  Content-Type: text/html; charset=utf-8

  <div style="font-family: Arial">Still broken after the update.</div><div><br></div><div class="protonmail_signature_block"><div class="protonmail_signature_block-user protonmail_signature_block-empty"></div><div class="protonmail_signature_block-proton">Sent with <a href="https://proton.me/mail/home">Proton Mail</a> secure email.</div></div><br><div class="protonmail_quote">On Wednesday, November 25th, 2026 at 2:30 PM, Quip Support &lt;no-reply-chatwoot@quip.network&gt; wrote:<br><blockquote class="protonmail_quote" type="cite">Thanks for the report. Can you try again after the update?<blockquote class="protonmail_quote" type="cite">It crashes when I open the wallet.</blockquote></blockquote><br></div>
  --b1--
MAIL

GMAIL_TEXT = <<~MAIL.freeze
  From: Test User <user@example.com>
  To: reply+fffa5ed9-0000-4000-8000-000000000000@reply.quip.network
  Subject: Re: Your ticket
  Message-ID: <quip-check-2@example.com>
  Content-Type: text/plain; charset=utf-8

  Works now, thanks!

  On Wed, Nov 25, 2026 at 2:30 PM Quip Support <no-reply-chatwoot@quip.network> wrote:

  > Thanks for the report. Can you try again after the update?
MAIL

ALL_QUOTE = <<~MAIL.freeze
  From: Test User <user@example.com>
  To: reply+fffa5ed9-0000-4000-8000-000000000000@reply.quip.network
  Subject: Re: Your ticket
  Message-ID: <quip-check-3@example.com>
  Content-Type: text/plain; charset=utf-8

  On Wed, Nov 25, 2026 at 2:30 PM Quip Support <no-reply-chatwoot@quip.network> wrote:

  > Thanks for the report. Can you try again after the update?
MAIL

def check(label, got, want)
  raise "#{label}: got #{got.inspect}, want #{want.inspect}" unless got == want

  puts "  ok: #{label}"
end

def ours(raw)
  mailbox = ReplyMailbox.allocate
  mailbox.processed_mail = MailPresenter.new(Mail.new(raw))
  mailbox.send(:mail_content)
end

def upstream(raw)
  mailbox = ReplyMailbox.allocate
  mailbox.processed_mail = MailPresenter.new(Mail.new(raw))
  MailboxHelper.instance_method(:mail_content).bind_call(mailbox)
end

check('ReplyMailbox#mail_content is ours', ReplyMailbox.instance_method(:mail_content).owner, QuipTrimmedEmailContent)
check('Proton reply: text only, no signature or thread', ours(PROTON), 'Still broken after the update.')
check('Proton reply: upstream would keep the thread', upstream(PROTON).include?('> > It crashes'), true)
html_only = PROTON.sub(%r{--b1\nContent-Type: text/plain.*?(?=--b1\n)}m, '')
check('Proton HTML-only reply', ours(html_only), 'Still broken after the update.')
check('Gmail plain-text reply', ours(GMAIL_TEXT), 'Works now, thanks!')
check('all-quote reply keeps upstream text', ours(ALL_QUOTE), upstream(ALL_QUOTE))
puts 'quip_email_reply check: ok'

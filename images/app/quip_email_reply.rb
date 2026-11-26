# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The message text an emailed reply gets.
#
# Upstream saves an emailed reply's whole body as the message text: what the
# user wrote, then their signature and every earlier message quoted below it.
# The bot, webhooks, the conversation list and search all read that text, so
# each reply drags the thread along. Chatwoot already runs EmailReplyTrimmer
# over the body and keeps the result under :quoted (upstream's name for the
# reply WITHOUT the quotes), so use that. The full email stays in
# content_attributes, so the desk's email view and its "show quoted text"
# toggle are unchanged.
#
# Pure Ruby, so test/quip_email_reply_test.rb runs without Rails.
module QuipEmailReply
  # text_content and html_content are MailPresenter's hashes,
  # {full:, reply:, quoted:}, or {} for a mail without that part. The part is
  # picked in upstream's order (MailboxHelper#mail_content): text, then HTML.
  # nil means "keep upstream's text": there is no part, or trimming left
  # nothing (a reply that is all quote).
  def self.content(text_content, html_content)
    part = [text_content, html_content].find { |p| p.is_a?(Hash) && !p.empty? }
    return nil unless part

    trimmed = part[:quoted]
    return nil unless trimmed.is_a?(String) && !trimmed.strip.empty?

    trimmed
  end
end

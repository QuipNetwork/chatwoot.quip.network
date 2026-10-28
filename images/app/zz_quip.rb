# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Quip deployment overrides for Chatwoot on Flux. Copied into
# config/initializers/ by images/app/Dockerfile; the zz_ prefix makes it load
# after upstream's initializers.

# FDM terminates TLS and forwards plain HTTP with no X-Forwarded-Proto (the
# wwwhttps frontend in flux-domain-manager's haproxyTemplate.js). Rails would
# then see http:// while browsers send an https:// Origin, and the CSRF origin
# check rejects every form POST with a 422 -- onboarding and the super-admin
# login among them. Every request we serve arrived over FDM's TLS, so tell
# Rails so. FORCE_SSL must stay false: Rails would redirect forever.
if ActiveModel::Type::Boolean.new.cast(ENV.fetch('QUIP_ASSUME_SSL', false))
  Rails.application.config.assume_ssl = true
end

# Chatwoot's hub calls send our installation id, version and hostname to
# hub.2.chatwoot.com daily, even with DISABLE_TELEMETRY (that only drops the
# counts), and onboarding's "subscribe" box sends the owner's name and email.
# None of it is needed to run a self-hosted install.
module QuipNoChatwootHub
  # CheckNewVersionsJob reads ['version'] from this, so a Hash, never nil.
  def sync_with_hub = {}
  def register_instance(*) = nil
  def send_push(*) = nil
  def send_push_with_response(*) = nil
  def emit_event(*) = nil
end

Rails.application.config.to_prepare do
  ChatwootHub.singleton_class.prepend(QuipNoChatwootHub)
end

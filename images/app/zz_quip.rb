# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Quip deployment overrides for Chatwoot on Flux. Copied into
# config/initializers/ by images/app/Dockerfile; the zz_ prefix makes it load
# after upstream's initializers.

# FDM terminates TLS and forwards plain HTTP with no X-Forwarded-Proto (the
# wwwhttps frontend in flux-domain-manager's haproxyTemplate.js). Rails then
# believes every request is http://, which breaks the super-admin console twice
# over (measured in the local rehearsal): its redirects and form actions are
# built as http:// URLs, and its CSRF origin check rejects every write with a
# 422 ("Origin https://... didn't match request.base_url http://..."). Every
# request we serve arrived over FDM's TLS, so tell Rails so. FORCE_SSL must
# stay false: Rails would redirect forever.
if ActiveModel::Type::Boolean.new.cast(ENV.fetch('QUIP_ASSUME_SSL', false))
  Rails.application.config.assume_ssl = true
end

# FDM's load balancers reach us from PUBLIC addresses, and Rack only trusts
# private ones as proxies, so Rack::Request#ip -- the key for every Rack::Attack
# throttle -- is the load balancer for every visitor (measured on Flux: /cable
# logged "for 134.209.107.70" = fdm-lb-1-3). One shared bucket means 5 bad
# logins from anyone lock every agent out. Trust exactly the FDM hostnames,
# resolved at boot: their requests yield the address FDM appended to
# X-Forwarded-For, and a direct hit on the node port with a forged header is
# still judged by its real source. No DNS answer means no extra trust.
# Re-resolved every 5 minutes, and an address stays trusted for 24 h after it
# was last seen: FDM flips some names between addresses (fdm-lb-2-1 alternates
# two IPs on a 15 s TTL), so one lookup is a sample, not the set.
require 'resolv'
require 'set'
module QuipTrustedProxies
  HOSTS = ENV.fetch('QUIP_TRUSTED_PROXY_HOSTS', '').split(',').map(&:strip).reject(&:empty?).freeze
  REFRESH_SECONDS = 300
  KEEP_SECONDS = 24 * 3600
  @seen = {}
  @ips = Set.new.freeze

  def self.ips = @ips

  # A failed lookup adds nothing and ages nothing out early.
  def self.refresh(now = Time.now)
    dns = Resolv::DNS.new.tap { |d| d.timeouts = 2 }
    HOSTS.each do |host|
      dns.getaddresses(host).each { |addr| @seen[addr.to_s] = now }
    rescue StandardError
      nil
    end
    @seen.delete_if { |_, last| now - last > KEEP_SECONDS }
    @ips = Set.new(@seen.keys).freeze
  ensure
    dns&.close
  end
end

if QuipTrustedProxies::HOSTS.any?
  QuipTrustedProxies.refresh
  rack_default_filter = Rack::Request.ip_filter
  Rack::Request.ip_filter = ->(ip) { rack_default_filter.call(ip) || QuipTrustedProxies.ips.include?(ip) }
  Thread.new do
    loop do
      sleep QuipTrustedProxies::REFRESH_SECONDS
      QuipTrustedProxies.refresh
    rescue StandardError
      nil
    end
  end
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

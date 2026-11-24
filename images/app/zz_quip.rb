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
  # 4.20 passes refresh_billing: (the daily job and Super Admin's refresh), so
  # take and ignore any keywords; without them every daily run would raise.
  def sync_with_hub(**) = {}
  def register_instance(*) = nil
  def send_push(*) = nil
  def send_push_with_response(*) = nil
  def emit_event(*) = nil
end

# /api reports data_services from `connection.active?`, which never connects:
# under Rails 7.2 it is false for a pooled connection that has not run a query
# yet. The pool reaper drops connections idle for 300 s, and on our own host
# /api runs no query (SwitchLocale looks up a Portal only for foreign hosts),
# so after any 5-minute lull it said "failing" until a real page load
# reconnected -- a false Offline on the support.quip.network monitor every few
# hours (measured 10-29). A real query connects when it can and raises when the
# database is down, so the answer is true either way.
module QuipHonestDbHealth
  private

  def postgres_status
    ActiveRecord::Base.connection.select_value('SELECT 1') == 1 ? 'ok' : 'failing'
  rescue ActiveRecord::ActiveRecordError
    'failing'
  end
end

# Memory warning for rails and sidekiq (config/quip_memory_watch.rb has the why
# and the arithmetic). Sidekiq has no HTTP port, so it reports through Redis;
# /api adds both readings and "memory_warning":true, which the desk.quip.network
# monitor turns into Degraded. No reading written means the key expires and /api
# warns, so a reporter that dies is noticed too.
require Rails.root.join('config/quip_memory_watch').to_s

Sidekiq.configure_server do |config|
  config.on(:startup) do
    Thread.new do
      loop do
        reading = QuipMemoryWatch.reading
        if reading
          Redis::Alfred.set(QuipMemoryWatch::SIDEKIQ_KEY, QuipMemoryWatch.payload(reading, Time.now.to_i),
                            ex: QuipMemoryWatch::KEY_TTL_SECONDS)
        end
      rescue StandardError => e
        Sidekiq.logger.warn("quip memory report failed: #{e.class}: #{e.message}")
      ensure
        sleep QuipMemoryWatch::REPORT_SECONDS
      end
    end
  end
end

# Upstream's index, plus the memory fields. Upstream's keys come first, in
# upstream's order, so the monitor's "data_services":"ok" match is untouched.
# 4.20 added mobile_app (the minimum app versions the mobile apps read); it is
# kept whenever upstream defines it.
module QuipMemoryInHealth
  def index
    sidekiq_json = begin
      Redis::Alfred.get(QuipMemoryWatch::SIDEKIQ_KEY)
    rescue StandardError
      nil
    end
    body = { version: Chatwoot.config[:version],
             timestamp: Time.now.utc.to_fs(:db),
             queue_services: redis_status,
             data_services: postgres_status }
    body[:mobile_app] = { min_version: mobile_app_min_versions } if respond_to?(:mobile_app_min_versions, true)
    render json: body.merge(QuipMemoryWatch.summary(rails: QuipMemoryWatch.reading, sidekiq_json: sidekiq_json,
                                                    now: Time.now.to_i))
  end
end

# desk.quip.network/handbook* is the support bot's handbook, proxied from here
# (config/quip_handbook_proxy.rb has the why). First in the stack, so no Rails
# middleware runs for it and its answers never carry our session cookie.
require Rails.root.join('config/quip_handbook_proxy').to_s
quip_handbook_upstream = ENV.fetch('QUIP_HANDBOOK_UPSTREAM', '')
if (upstream = QuipHandbookProxy.upstream_from_env(quip_handbook_upstream))
  Rails.application.config.middleware.insert_before(0, QuipHandbookProxy, upstream: upstream, logger: Rails.logger)
elsif !quip_handbook_upstream.strip.empty?
  Rails.logger.warn('QUIP_HANDBOOK_UPSTREAM is not a bare http(s) origin; /handbook is not proxied')
end

Rails.application.config.to_prepare do
  ChatwootHub.singleton_class.prepend(QuipNoChatwootHub)
  ApiController.prepend(QuipHonestDbHealth)
  ApiController.prepend(QuipMemoryInHealth)
end

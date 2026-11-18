# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Memory warning for the rails and sidekiq containers (pure Ruby, no Rails, so
# test/quip_memory_watch_test.rb can load it on its own). zz_quip.rb wires it in:
# sidekiq writes its reading to Redis every REPORT_SECONDS, and /api reports
# both, with "memory_warning":true when either is at WARN_PERCENT of its cap or
# a reading is missing or stale. The desk.quip.network monitor goes Degraded on
# that string, so a reporter that stops reporting warns instead of going quiet.
#
# Why: Chatwoot's memory has grown since v4.9 (chatwoot#13280), and Flux's cap
# per container is hard (2 GB each): past it the kernel kills the process.
#
# The reading is the container's working set: cgroup usage minus inactive page
# cache, the figure `docker stats` and the kubelet use. Raw usage counts cache
# the kernel drops before it would kill anything, so it reads high for no reason.
require 'json'

module QuipMemoryWatch
  WARN_PERCENT = Integer(ENV.fetch('QUIP_MEMORY_WARN_PERCENT', '80'))
  SIDEKIQ_KEY = 'quip:memory:sidekiq'.freeze
  REPORT_SECONDS = 60
  STALE_SECONDS = 180 # three missed reports
  KEY_TTL_SECONDS = 600
  NO_LIMIT_V1 = 2**60 # v1 reports "no cap" as a number near 2^63
  MB = 1024 * 1024

  module_function

  # { 'used_mb', 'limit_mb', 'percent' } for this container, or nil when there
  # is no cap to measure against or the files can't be read.
  def reading(v2_root: '/sys/fs/cgroup', v1_root: '/sys/fs/cgroup/memory')
    limit, usage, inactive =
      if File.exist?(File.join(v2_root, 'memory.max'))
        raw = File.read(File.join(v2_root, 'memory.max')).strip
        return nil if raw == 'max'

        [Integer(raw), Integer(File.read(File.join(v2_root, 'memory.current')).strip),
         stat(v2_root)['inactive_file']]
      elsif File.exist?(File.join(v1_root, 'memory.limit_in_bytes'))
        raw = Integer(File.read(File.join(v1_root, 'memory.limit_in_bytes')).strip)
        return nil if raw >= NO_LIMIT_V1

        [raw, Integer(File.read(File.join(v1_root, 'memory.usage_in_bytes')).strip),
         stat(v1_root)['total_inactive_file']]
      else
        return nil
      end
    return nil unless limit.positive?

    used = [usage - inactive.to_i, 0].max
    { 'used_mb' => used / MB, 'limit_mb' => limit / MB, 'percent' => (used * 100.0 / limit).round(1) }
  rescue StandardError
    nil
  end

  def stat(root)
    File.foreach(File.join(root, 'memory.stat')).to_h do |line|
      key, value = line.split
      [key, value.to_i]
    end
  end

  # What sidekiq stores in Redis: its reading plus when it was taken.
  def payload(reading, now)
    JSON.generate(reading.merge('at' => now))
  end

  # The fields /api adds. high beats unknown: a known overrun is the more
  # useful thing to say.
  def summary(rails:, sidekiq_json:, now:, warn_percent: WARN_PERCENT)
    sidekiq = parse(sidekiq_json, now)
    readings = [rails, sidekiq]
    state =
      if readings.compact.any? { |r| r['percent'] >= warn_percent } then 'high'
      elsif readings.any?(&:nil?) then 'unknown'
      else 'ok'
      end
    { 'memory' => state, 'memory_warning' => state != 'ok',
      'memory_detail' => { 'rails' => rails, 'sidekiq' => sidekiq } }
  end

  def parse(json, now)
    return nil if json.nil?

    data = JSON.parse(json)
    age = now - Integer(data.delete('at'))
    return nil if age > STALE_SECONDS

    data.merge('age_s' => age)
  rescue StandardError
    nil
  end
end

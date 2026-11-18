# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Run inside the app image (it has Ruby and minitest), from the repo root:
#   docker run --rm --network none -v "$PWD/images/app:/q:ro" --entrypoint ruby \
#     <app image> /q/test/quip_memory_watch_test.rb
require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require_relative '../quip_memory_watch'

MB = 1024 * 1024

class QuipMemoryWatchReadingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @v2 = File.join(@dir, 'v2')
    @v1 = File.join(@dir, 'v1')
    FileUtils.mkdir_p([@v2, @v1])
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write(root, name, text)
    File.write(File.join(root, name), text)
  end

  def reading
    QuipMemoryWatch.reading(v2_root: @v2, v1_root: @v1)
  end

  def test_cgroup_v2_working_set_leaves_out_inactive_page_cache
    write(@v2, 'memory.max', "#{2048 * MB}\n")
    write(@v2, 'memory.current', "#{1024 * MB}\n")
    write(@v2, 'memory.stat', "anon #{700 * MB}\nfile #{324 * MB}\ninactive_file #{256 * MB}\nactive_file #{68 * MB}\n")
    assert_equal({ 'used_mb' => 768, 'limit_mb' => 2048, 'percent' => 37.5 }, reading)
  end

  def test_cgroup_v1_is_read_when_there_is_no_v2
    write(@v1, 'memory.limit_in_bytes', "#{2048 * MB}\n")
    write(@v1, 'memory.usage_in_bytes', "#{1800 * MB}\n")
    write(@v1, 'memory.stat', "cache #{100 * MB}\ninactive_file #{1 * MB}\ntotal_inactive_file #{160 * MB}\n")
    assert_equal({ 'used_mb' => 1640, 'limit_mb' => 2048, 'percent' => 80.1 }, reading)
  end

  def test_no_cap_on_v2_gives_no_reading
    write(@v2, 'memory.max', "max\n")
    write(@v2, 'memory.current', "#{1024 * MB}\n")
    write(@v2, 'memory.stat', "inactive_file 0\n")
    assert_nil reading
  end

  def test_no_cap_on_v1_gives_no_reading
    write(@v1, 'memory.limit_in_bytes', "9223372036854771712\n")
    write(@v1, 'memory.usage_in_bytes', "#{1024 * MB}\n")
    write(@v1, 'memory.stat', "total_inactive_file 0\n")
    assert_nil reading
  end

  def test_no_cgroup_files_gives_no_reading
    assert_nil reading
  end

  def test_working_set_never_goes_negative
    write(@v2, 'memory.max', "#{2048 * MB}\n")
    write(@v2, 'memory.current', "#{10 * MB}\n")
    write(@v2, 'memory.stat', "inactive_file #{20 * MB}\n")
    assert_equal({ 'used_mb' => 0, 'limit_mb' => 2048, 'percent' => 0.0 }, reading)
  end
end

class QuipMemoryWatchSummaryTest < Minitest::Test
  NOW = 1_800_000_000

  def at(percent)
    { 'used_mb' => (percent * 20.48).round, 'limit_mb' => 2048, 'percent' => percent }
  end

  def summary(rails:, sidekiq:, age: 30)
    json = sidekiq && QuipMemoryWatch.payload(sidekiq, NOW - age)
    QuipMemoryWatch.summary(rails: rails, sidekiq_json: json, now: NOW, warn_percent: 80)
  end

  def test_both_under_the_threshold_is_ok
    s = summary(rails: at(40.0), sidekiq: at(55.5))
    assert_equal 'ok', s['memory']
    assert_equal false, s['memory_warning']
    assert_equal at(40.0), s['memory_detail']['rails']
    assert_equal at(55.5).merge('age_s' => 30), s['memory_detail']['sidekiq']
  end

  def test_rails_at_the_threshold_warns
    s = summary(rails: at(80.0), sidekiq: at(10.0))
    assert_equal 'high', s['memory']
    assert_equal true, s['memory_warning']
  end

  def test_sidekiq_over_the_threshold_warns
    s = summary(rails: at(10.0), sidekiq: at(91.2))
    assert_equal 'high', s['memory']
    assert_equal true, s['memory_warning']
  end

  def test_a_stale_sidekiq_reading_warns_as_unknown
    s = summary(rails: at(10.0), sidekiq: at(10.0), age: 181)
    assert_equal 'unknown', s['memory']
    assert_equal true, s['memory_warning']
    assert_nil s['memory_detail']['sidekiq']
  end

  def test_a_missing_sidekiq_reading_warns_as_unknown
    s = summary(rails: at(10.0), sidekiq: nil)
    assert_equal 'unknown', s['memory']
    assert_equal true, s['memory_warning']
  end

  def test_a_garbled_sidekiq_reading_warns_as_unknown
    s = QuipMemoryWatch.summary(rails: at(10.0), sidekiq_json: '{not json', now: NOW, warn_percent: 80)
    assert_equal 'unknown', s['memory']
    assert_equal true, s['memory_warning']
  end

  def test_no_rails_reading_warns_as_unknown
    s = summary(rails: nil, sidekiq: at(10.0))
    assert_equal 'unknown', s['memory']
    assert_equal true, s['memory_warning']
  end

  def test_high_wins_over_unknown
    s = summary(rails: at(95.0), sidekiq: nil)
    assert_equal 'high', s['memory']
  end

  def test_the_warning_renders_as_the_string_the_monitor_matches
    body = JSON.generate(summary(rails: at(85.0), sidekiq: at(10.0)))
    assert_includes body, '"memory_warning":true'
    refute_includes JSON.generate(summary(rails: at(5.0), sidekiq: at(5.0))), '"memory_warning":true'
  end
end

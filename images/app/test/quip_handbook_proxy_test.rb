# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Run inside the app image (it has Ruby and minitest), from the repo root:
#   docker run --rm --network none -v "$PWD/images/app:/q:ro" --entrypoint ruby \
#     <app image> /q/test/quip_handbook_proxy_test.rb
# The bot is a stub HTTP server on loopback.
require 'minitest/autorun'
require 'socket'
require 'logger'
require 'stringio'
require 'zlib'
require_relative '../quip_handbook_proxy'

class StubUpstream
  attr_reader :port

  def initialize(&handler)
    @handler = handler
    @lock = Mutex.new
    @requests = []
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @thread = Thread.new do
      loop { Thread.new(@server.accept) { |sock| serve(sock) } }
    rescue IOError, SystemCallError
      nil
    end
  end

  def url = "http://127.0.0.1:#{@port}"
  def requests = @lock.synchronize { @requests.dup }

  def stop
    @server.close
    @thread.join(1)
  end

  private

  def serve(sock)
    method, target, = sock.gets("\r\n").to_s.split(' ')
    headers = {}
    while (line = sock.gets("\r\n")) && line != "\r\n"
      name, value = line.chomp("\r\n").split(':', 2)
      headers[name.downcase] = value.to_s.strip
    end
    req = { method: method, target: target, headers: headers }
    @lock.synchronize { @requests << req }
    status, extra, body = @handler.call(req)
    out = +"HTTP/1.1 #{status} Stub\r\n"
    extra.each { |k, v| Array(v).each { |one| out << "#{k}: #{one}\r\n" } }
    out << "content-length: #{body.bytesize}\r\nconnection: close\r\n\r\n"
    sock.write(out)
    sock.write(body) unless method == 'HEAD'
  rescue IOError, SystemCallError
    nil
  ensure
    sock.close
  end
end

class QuipHandbookProxyTest < Minitest::Test
  APP = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['chatwoot']] }
  PAGE = ->(_req) { [200, { 'content-type' => 'text/html; charset=utf-8' }, '<h1>handbook</h1>'] }

  def setup
    @log = StringIO.new
    @upstreams = []
  end

  def teardown
    @upstreams.each(&:stop)
  end

  def upstream(&handler)
    StubUpstream.new(&(handler || PAGE)).tap { |u| @upstreams << u }
  end

  def proxy(up, **opts)
    target = up.is_a?(String) ? up : up.url
    QuipHandbookProxy.new(APP, upstream: target, logger: Logger.new(@log), open_timeout: 1, read_timeout: 1,
                               wait_seconds: 0.5, circuit_seconds: 30, **opts)
  end

  def env(path, method: 'GET', query: '', **headers)
    { 'REQUEST_METHOD' => method, 'PATH_INFO' => path, 'QUERY_STRING' => query,
      'HTTP_HOST' => 'desk.quip.network' }.merge(headers)
  end

  def call(app, path, **kw)
    status, headers, body = app.call(env(path, **kw))
    [status, headers, body.join]
  end

  def test_forwards_path_and_query
    up = upstream
    status, headers, body = call(proxy(up), '/handbook/assets/support.css', query: 'v=3')
    assert_equal 200, status
    assert_equal '<h1>handbook</h1>', body
    assert_equal 'text/html; charset=utf-8', headers['content-type']
    assert_equal '/handbook/assets/support.css?v=3', up.requests.first[:target]
    assert_equal 'GET', up.requests.first[:method]
  end

  def test_forwards_only_the_session_cookie
    up = upstream
    call(proxy(up), '/handbook',
         'HTTP_COOKIE' => '_chatwoot_session=abc; cw_d_session_info=%7B%22uid%22%3A%22a%40b%22%7D; other=1',
         'HTTP_X_FORWARDED_FOR' => '203.0.113.9', 'HTTP_AUTHORIZATION' => 'Bearer x',
         'HTTP_USER_AGENT' => 'Firefox', 'HTTP_ACCEPT' => 'text/html')
    sent = up.requests.first[:headers]
    assert_equal 'cw_d_session_info=%7B%22uid%22%3A%22a%40b%22%7D', sent['cookie']
    assert_equal 'quip-desk-handbook-proxy', sent['user-agent']
    assert_equal 'text/html', sent['accept']
    refute sent.key?('x-forwarded-for')
    refute sent.key?('authorization')
  end

  def test_no_cookie_without_a_session
    up = upstream
    call(proxy(up), '/handbook', 'HTTP_COOKIE' => '_chatwoot_session=abc')
    refute up.requests.first[:headers].key?('cookie')
  end

  def test_unprintable_session_cookie_is_not_forwarded
    up = upstream
    call(proxy(up), '/handbook', 'HTTP_COOKIE' => "cw_d_session_info=a\tb")
    refute up.requests.first[:headers].key?('cookie')
  end

  def test_drops_set_cookie_and_unlisted_headers
    up = upstream do
      [200, { 'content-type' => 'text/html', 'set-cookie' => %w[a=1 b=2], 'server' => 'Fly',
              'content-security-policy' => "default-src 'self'", 'x-robots-tag' => 'noindex',
              'cache-control' => 'private, max-age=3600', 'x-frame-options' => 'DENY' }, 'ok']
    end
    _, headers, = call(proxy(up), '/handbook')
    refute headers.key?('set-cookie')
    refute headers.key?('server')
    assert_equal "default-src 'self'", headers['content-security-policy']
    assert_equal 'noindex', headers['x-robots-tag']
    assert_equal 'private, max-age=3600', headers['cache-control']
    assert_equal 'DENY', headers['x-frame-options']
  end

  def test_defaults_cache_control_and_nosniff
    up = upstream { [200, { 'content-type' => 'text/css' }, 'a{}'] }
    _, headers, = call(proxy(up), '/handbook/assets/a.css')
    assert_equal 'private, no-store', headers['cache-control']
    assert_equal 'nosniff', headers['x-content-type-options']
  end

  def test_passes_error_statuses_through
    [401, 404, 503].each do |code|
      up = upstream { [code, { 'content-type' => 'text/html' }, "page #{code}"] }
      status, _, body = call(proxy(up), '/handbook')
      assert_equal code, status
      assert_equal "page #{code}", body
    end
  end

  def test_gzip_answer_is_decoded
    up = upstream do
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io)
      gz.write('plain text')
      gz.close
      [200, { 'content-type' => 'text/plain', 'content-encoding' => 'gzip' }, io.string]
    end
    _, headers, body = call(proxy(up), '/handbook')
    assert_equal 'plain text', body
    refute headers.key?('content-encoding')
  end

  def test_redirects_stay_under_handbook
    {
      '/handbook/' => '/handbook/',
      'https://desk.quip.network/handbook/x' => 'https://desk.quip.network/handbook/x'
    }.each do |location, kept|
      up = upstream { [302, { 'location' => location }, ''] }
      status, headers, = call(proxy(up), '/handbook')
      assert_equal 302, status
      assert_equal kept, headers['location']
    end
    ['https://evil.example/handbook', '//evil.example/handbook', '/app/login', 'http://desk.quip.network/handbook',
     'https://u@desk.quip.network/handbook', '/handbookx'].each do |location|
      up = upstream { [302, { 'location' => location }, ''] }
      status, headers, = call(proxy(up), '/handbook')
      assert_equal 502, status, location
      refute headers.key?('location')
    end
  end

  def test_refuses_odd_paths_without_forwarding
    up = upstream
    app = proxy(up)
    ['/handbook/../api', '/handbook/%2e%2e/api', '/handbook//x', '/handbook//', '/handbook/./x', '/handbook/a/..',
     '/handbook/a b', '/handbook/a\\b', '/handbook/a%2Fb', '/handbook/a//'].each do |path|
      status, = call(app, path)
      assert_equal 404, status, path
    end
    assert_empty up.requests
  end

  def test_allows_plain_paths
    up = upstream
    app = proxy(up)
    ['/handbook', '/handbook/', '/handbook/assets/fonts/x.woff2', '/handbook/a/', '/handbook/theme.js'].each do |path|
      status, = call(app, path)
      assert_equal 200, status, path
    end
    assert_equal 5, up.requests.length
  end

  def test_other_paths_go_to_chatwoot
    up = upstream
    app = proxy(up)
    ['/handbookx', '/app/login', '/', '/api', '/x/handbook'].each do |path|
      status, _, body = call(app, path)
      assert_equal [200, 'chatwoot'], [status, body], path
    end
    assert_empty up.requests
  end

  def test_only_get_and_head
    up = upstream
    app = proxy(up)
    %w[POST PUT PATCH DELETE OPTIONS].each do |method|
      status, headers, = call(app, '/handbook', method: method)
      assert_equal 405, status, method
      assert_equal 'GET, HEAD', headers['allow']
    end
    assert_empty up.requests
    status, _, body = call(app, '/handbook', method: 'HEAD')
    assert_equal 200, status
    assert_equal '', body
    assert_equal 'HEAD', up.requests.first[:method]
  end

  def test_refuses_bad_queries
    up = upstream
    app = proxy(up)
    assert_equal 400, call(app, '/handbook', query: 'a b').first
    assert_equal 400, call(app, '/handbook', query: 'x' * 2049).first
    assert_empty up.requests
  end

  def test_timeout_opens_the_circuit
    slow = true
    up = upstream do |_req|
      sleep 2 if slow
      [200, { 'content-type' => 'text/plain' }, 'ok']
    end
    app = proxy(up, read_timeout: 0.2, circuit_seconds: 0.5)
    status, headers, = call(app, '/handbook')
    assert_equal 502, status
    assert_equal '0', headers['retry-after']
    slow = false
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal 502, call(app, '/handbook').first
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.1
    assert_equal 1, up.requests.length
    sleep 0.6
    assert_equal 200, call(app, '/handbook').first
    assert_equal 2, up.requests.length
  end

  def test_connect_refused_opens_the_circuit
    closed = TCPServer.new('127.0.0.1', 0)
    port = closed.addr[1]
    closed.close
    app = proxy("http://127.0.0.1:#{port}")
    assert_equal 502, call(app, '/handbook').first
    assert_includes @log.string, 'Errno::ECONNREFUSED'
    assert_equal 502, call(app, '/handbook').first
    assert_includes @log.string, 'circuit open'
  end

  def test_caps_requests_in_flight
    gate = Queue.new
    up = upstream do |_req|
      gate.pop
      [200, { 'content-type' => 'text/plain' }, 'ok']
    end
    app = proxy(up, max_inflight: 2, wait_seconds: 0.2, read_timeout: 5)
    waiting = Array.new(2) { Thread.new { call(app, '/handbook').first } }
    sleep 0.05 until up.requests.length == 2
    status, headers, = call(app, '/handbook')
    assert_equal 503, status
    assert_equal '2', headers['retry-after']
    2.times { gate << :go }
    assert_equal [200, 200], waiting.map(&:value)
    gate << :go
    assert_equal 200, call(app, '/handbook').first
  end

  def test_body_cap_does_not_open_the_circuit
    big = true
    up = upstream { [200, { 'content-type' => 'text/plain' }, big ? 'x' * 500 : 'small'] }
    app = proxy(up, max_body: 100)
    assert_equal 502, call(app, '/handbook').first
    big = false
    status, _, body = call(app, '/handbook')
    assert_equal [200, 'small'], [status, body]
  end

  def test_log_has_no_query_or_cookie
    up = upstream
    call(proxy(up), '/handbook/assets/a.css', query: 'token=secret123',
                                              'HTTP_COOKIE' => 'cw_d_session_info=tokenvalue456')
    assert_match %r{handbook proxy GET /handbook/assets/a\.css -> 200 in \d+ ms}, @log.string
    refute_includes @log.string, 'secret123'
    refute_includes @log.string, 'tokenvalue456'
  end

  def test_upstream_from_env
    assert_nil QuipHandbookProxy.upstream_from_env('')
    assert_nil QuipHandbookProxy.upstream_from_env('   ')
    assert_equal 'quip-support-bot.fly.dev', QuipHandbookProxy.upstream_from_env('https://quip-support-bot.fly.dev').host
    assert_equal 'x.example', QuipHandbookProxy.upstream_from_env(' https://x.example/ ').host
    ['https://x.example/team', 'ftp://x.example', 'https://u:p@x.example', 'https://x.example?a=1', 'x.example',
     'https://', 'not a url'].each do |bad|
      assert_nil QuipHandbookProxy.upstream_from_env(bad), bad
    end
  end
end

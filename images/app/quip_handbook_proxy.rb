# SPDX-License-Identifier: AGPL-3.0-or-later
#
# desk.quip.network/handbook and everything under it is the support bot's
# handbook (quip-support-bot on Fly). FDM routes by hostname only, so the path
# rule lives here, as the first middleware. The bot shows the page only to
# people signed in to our Chatwoot: it reads the dashboard's cw_d_session_info
# cookie and checks it against /api/v1/profile. That cookie is the only one we
# forward, and nothing the bot answers can set a cookie on this host.
#
# Puma runs 5 threads in one process, and a forwarded request holds one until
# the bot answers. So: short timeouts, at most max_inflight forwards at once,
# and after a connect error or timeout every request fails fast for
# circuit_seconds instead of waiting on a bot that is down.
require 'net/http'
require 'openssl'
require 'uri'
require 'zlib'

class QuipHandbookProxy
  PREFIX = '/handbook'
  SESSION_COOKIE = 'cw_d_session_info'
  SEGMENT = /\A[A-Za-z0-9._~-]+\z/
  QUERY = /\A[\x21-\x7e]{0,2048}\z/
  PRINTABLE = /\A[\x21-\x7e]+\z/
  RESPONSE_HEADERS = %w[content-type cache-control content-security-policy x-content-type-options
                        x-robots-tag referrer-policy permissions-policy x-frame-options].freeze
  UPSTREAM_ERRORS = [Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError,
                     Net::ProtocolError, Zlib::Error].freeze
  UNAVAILABLE = "The handbook can't be reached right now. Try again in a minute.\n"
  BUSY = "The handbook is busy. Try again in a moment.\n"

  class TooLarge < StandardError; end

  # The upstream origin, or nil when unset or not a bare http(s) origin.
  def self.upstream_from_env(value = ENV.fetch('QUIP_HANDBOOK_UPSTREAM', ''))
    uri = URI.parse(value.to_s.strip)
    return nil unless %w[http https].include?(uri.scheme) && uri.host.to_s != ''
    return nil unless uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && ['', '/'].include?(uri.path)

    uri
  rescue URI::InvalidURIError
    nil
  end

  def initialize(app, upstream:, logger: nil, open_timeout: 3, read_timeout: 8, max_inflight: 3,
                 wait_seconds: 3, circuit_seconds: 30, max_body: 10 * 1024 * 1024)
    @app = app
    @upstream = upstream.is_a?(URI::Generic) ? upstream : URI.parse(upstream.to_s)
    @logger = logger
    @open_timeout = open_timeout
    @read_timeout = read_timeout
    @max_inflight = max_inflight
    @wait_seconds = wait_seconds
    @circuit_seconds = circuit_seconds
    @max_body = max_body
    @lock = Mutex.new
    @freed = ConditionVariable.new
    @inflight = 0
    @open_until = 0.0
  end

  def call(env)
    path = env['PATH_INFO'].to_s
    return @app.call(env) unless path == PREFIX || path.start_with?("#{PREFIX}/")

    started = now
    status, headers, body, note = handle(env, path)
    log(env['REQUEST_METHOD'], path, status, started, note)
    [status, headers, body]
  end

  private

  def handle(env, path)
    return refuse(404, "Not found\n") unless allowed_path?(path)

    method = env['REQUEST_METHOD'].to_s
    return refuse(405, "Method not allowed\n", 'allow' => 'GET, HEAD') unless %w[GET HEAD].include?(method)

    query = env['QUERY_STRING'].to_s
    return refuse(400, "Bad request\n") unless query.match?(QUERY)
    return unavailable('circuit open') if circuit_open?
    return refuse(503, BUSY, { 'retry-after' => '2' }, 'busy') unless acquire

    begin
      return unavailable('circuit open') if circuit_open?

      forward(env, method, query.empty? ? path : "#{path}?#{query}")
    ensure
      release
    end
  end

  # /handbook, /handbook/ and plain segments under it. No empty, "." or ".."
  # segment and no percent-encoding, so the bot can't be steered off /handbook.
  def allowed_path?(path)
    return true if path == PREFIX || path == "#{PREFIX}/"

    segments = path.delete_prefix("#{PREFIX}/").delete_suffix('/').split('/', -1)
    !segments.empty? && segments.all? { |s| s.match?(SEGMENT) && s != '.' && s != '..' }
  end

  def forward(env, method, target)
    req = (method == 'HEAD' ? Net::HTTP::Head : Net::HTTP::Get).new(target)
    req['user-agent'] = 'quip-desk-handbook-proxy'
    accept = env['HTTP_ACCEPT'].to_s
    req['accept'] = accept if accept.length.between?(1, 512) && accept.match?(/\A[\x20-\x7e]+\z/)
    cookie = session_cookie(env['HTTP_COOKIE'])
    req['cookie'] = "#{SESSION_COOKIE}=#{cookie}" if cookie

    status = nil
    headers = nil
    body = String.new(encoding: Encoding::BINARY)
    http = Net::HTTP.new(@upstream.host, @upstream.port, nil)
    http.use_ssl = @upstream.scheme == 'https'
    http.open_timeout = @open_timeout # covers the TLS handshake too
    http.write_timeout = @open_timeout
    http.read_timeout = @read_timeout
    http.max_retries = 0 # Net::HTTP retries a timed-out GET once, doubling the time a thread waits
    http.start do |h|
      h.request(req) do |res|
        status = res.code.to_i
        headers = response_headers(res, env)
        res.read_body do |chunk|
          body << chunk.b
          raise TooLarge if body.bytesize > @max_body
        end
      end
    end
    return unavailable('redirect off /handbook') if status.between?(300, 399) && !headers.key?('location')
    return unavailable("status #{status}") unless status.between?(200, 599)

    [status, headers, method == 'HEAD' ? [] : [body], nil]
  rescue TooLarge
    unavailable('body too large')
  rescue *UPSTREAM_ERRORS => e
    trip!
    unavailable(e.class.name)
  end

  def response_headers(res, env)
    out = {}
    res.each_header { |name, value| out[name] = value if RESPONSE_HEADERS.include?(name) }
    location = res['location'].to_s
    out['location'] = location if location != '' && own_location?(location, env)
    out['cache-control'] ||= 'private, no-store'
    out['x-content-type-options'] ||= 'nosniff'
    out
  end

  # Redirects stay under /handbook on this host.
  def own_location?(location, env)
    uri = URI.parse(location)
    return false unless uri.userinfo.nil?
    return false unless (uri.scheme.nil? && uri.host.nil?) || (uri.scheme == 'https' && uri.host == env['HTTP_HOST'])

    uri.path == PREFIX || uri.path.start_with?("#{PREFIX}/")
  rescue URI::InvalidURIError
    false
  end

  def session_cookie(header)
    header.to_s.split(';').each do |part|
      name, value = part.strip.split('=', 2)
      next unless name == SESSION_COOKIE

      return value.to_s.length <= 8192 && value.to_s.match?(PRINTABLE) ? value : nil
    end
    nil
  end

  def acquire
    deadline = now + @wait_seconds
    @lock.synchronize do
      while @inflight >= @max_inflight
        left = deadline - now
        return false if left <= 0

        @freed.wait(@lock, left)
      end
      @inflight += 1
    end
    true
  end

  def release
    @lock.synchronize do
      @inflight -= 1
      @freed.signal
    end
  end

  def circuit_open? = @lock.synchronize { now < @open_until }

  def trip!
    @lock.synchronize { @open_until = now + @circuit_seconds }
  end

  def unavailable(note)
    refuse(502, UNAVAILABLE, { 'retry-after' => @circuit_seconds.to_i.to_s }, note)
  end

  def refuse(status, text, extra = {}, note = nil)
    [status, { 'content-type' => 'text/plain; charset=utf-8', 'cache-control' => 'no-store',
               'x-content-type-options' => 'nosniff' }.merge(extra), [text], note]
  end

  # Never the query or any header: the cookie carries the reader's tokens.
  def log(method, path, status, started, note)
    return unless @logger

    ms = ((now - started) * 1000).round
    shown = path.gsub(/[^\x21-\x7e]/, '?')[0, 200]
    @logger.info("handbook proxy #{method.to_s[0, 10]} #{shown} -> #{status} in #{ms} ms#{" (#{note})" if note}")
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

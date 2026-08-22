require "httparty"

# A development-only replacement for the Cloudflare Worker routes that have no Middleman page. Thus
# `middleman server` renders a complete page and does not remove each widget. The
# `configure :development` block of config.rb registers it. `middleman build` never uses it.
#
# ⚠️ This is NOT a copy of web/src/api-proxy.ts and it must not become one. Each rule in that file —
# the Age header that goes through, the ETag revalidation, an upstream request with the same bytes
# for each shared cache entry, and the removal of the query string — exists to make one Cloudflare
# edge cache entry safe for many viewers. Here there is no edge and there is one viewer. Thus this
# code sends the status, the content type, and the body, and nothing more.
class DevApiProxy
  WIDGET_PREFIX = "/widgets/"
  CONTACT_PATH = "/api/contact"

  # This is long, as it is in the Worker: the api can be a fly machine that starts from zero, or a
  # local Rails that did not complete its start.
  TIMEOUT = 30

  # @param app [#call] The Rack app below this one, which is Middleman.
  def initialize(app)
    @app = app
  end

  # @param env [Hash] The Rack environment.
  # @return [Array(Integer, Hash, Array<String>)] The upstream response, or the response of the
  #   app below this one.
  def call(env)
    path = env["PATH_INFO"]
    return @app.call(env) unless proxied?(env, path)

    base = ENV["KONA_API_URL"].to_s
    return bad_gateway("KONA_API_URL is not set") if base.empty?

    forward(env, path, URI.join(base, path).to_s)
  end

  private

  # Only the two routes that the Worker takes, and only with the methods that it permits. `/pa/*` is
  # absent, on purpose: a local page view must not reach Plausible.
  def proxied?(env, path)
    method = env["REQUEST_METHOD"]
    return true if path.start_with?(WIDGET_PREFIX) && %w[GET HEAD].include?(method)

    path == CONTACT_PATH && method == "POST"
  end

  # @param url [String] The full upstream URL, for the failure log.
  def forward(env, path, url)
    response = if path == CONTACT_PATH
      HTTParty.post(url, headers: contact_headers(env), body: env["rack.input"].read,
                         timeout: TIMEOUT, follow_redirects: false)
    else
      HTTParty.get(url, headers: auth_headers, timeout: TIMEOUT)
    end

    rack_response(response)
  rescue StandardError => e
    bad_gateway("#{url} -> #{e.class}: #{e.message}")
  end

  # The shared bearer token, which the server adds, in the same way as the Worker.
  def auth_headers
    token = ENV["API_TOKEN"].to_s
    token.empty? ? {} : { "authorization" => "Bearer #{token}" }
  end

  # In production, Cloudflare is in front of the api and the api cannot see the visitor. Thus the
  # Worker sends the true data in the X-Kona-Client-* headers. Akismet, the notification email, and
  # the rack-attack throttle of the api read them. Thus you cannot test the contact form locally
  # without them.
  def contact_headers(env)
    headers = auth_headers
    headers["accept"] = env["HTTP_ACCEPT"] if env["HTTP_ACCEPT"]
    headers["content-type"] = env["CONTENT_TYPE"] if env["CONTENT_TYPE"]
    headers["x-kona-client-ip"] = env["REMOTE_ADDR"] if env["REMOTE_ADDR"]
    headers["x-kona-client-ua"] = env["HTTP_USER_AGENT"] if env["HTTP_USER_AGENT"]
    headers
  end

  # The status goes through with no change: an empty 200 is the "no data" answer of the api and must
  # remove the widget, and a non-2xx must not change content that the page already shows.
  # `no-store` is different from the production `max-age=0, stale-while-revalidate=N`, on purpose.
  # Thus a new page load always shows the render that you just changed.
  def rack_response(response)
    headers = { "cache-control" => "no-store" }
    headers["content-type"] = response.headers["content-type"] if response.headers["content-type"]
    # The contact path with no JavaScript answers with a 303.
    headers["location"] = response.headers["location"] if response.headers["location"]

    [ response.code, headers, [ response.body.to_s ] ]
  end

  # This is the same as the empty 502 of the Worker. The message is the only record of an api with
  # an incorrect configuration, or an api that the code cannot reach. The widget goes away and gives
  # no message.
  def bad_gateway(message)
    warn "== DevApiProxy: #{message}"
    [ 502, { "cache-control" => "no-store" }, [ "" ] ]
  end
end

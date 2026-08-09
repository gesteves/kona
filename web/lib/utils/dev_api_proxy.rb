require "httparty"

# Dev-only stand-in for the Cloudflare Worker routes that have no Middleman page behind them, so
# `middleman server` renders a complete page instead of collapsing every widget. Registered from
# config.rb's `configure :development` block; never reached by `middleman build`.
#
# ⚠️ This is NOT a port of web/src/api-proxy.ts and must not become one. Every invariant that file
# documents — Age passthrough, ETag revalidation, a byte-identical upstream request per shared
# cache entry, the query-string strip — exists to make one Cloudflare edge cache entry safe for
# many viewers. Here there is no edge and one viewer, so this forwards the status, content type
# and body, and nothing else.
class DevApiProxy
  WIDGET_PREFIX = "/widgets/"
  CONTACT_PATH = "/api/contact"

  # Generous, like the Worker's: the api may be a fly machine cold-starting from zero, or a local
  # Rails that hasn't finished booting.
  TIMEOUT = 30

  # @param app [#call] The inner Rack app (Middleman).
  def initialize(app)
    @app = app
  end

  # @param env [Hash] The Rack environment.
  # @return [Array(Integer, Hash, Array<String>)] The upstream response, or the inner app's.
  def call(env)
    path = env["PATH_INFO"]
    return @app.call(env) unless proxied?(env, path)

    base = ENV["KONA_API_URL"].to_s
    return bad_gateway("KONA_API_URL is not set") if base.empty?

    forward(env, path, URI.join(base, path).to_s)
  end

  private

  # Only the two routes the Worker claims, and only with the methods it allows. `/pa/*` is
  # deliberately absent: local page views shouldn't reach Plausible.
  def proxied?(env, path)
    method = env["REQUEST_METHOD"]
    return true if path.start_with?(WIDGET_PREFIX) && %w[GET HEAD].include?(method)

    path == CONTACT_PATH && method == "POST"
  end

  # @param url [String] The resolved upstream URL, used in the failure log.
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

  # The shared bearer, injected server-side exactly as the Worker does.
  def auth_headers
    token = ENV["API_TOKEN"].to_s
    token.empty? ? {} : { "authorization" => "Bearer #{token}" }
  end

  # In production the api sits behind Cloudflare and can't see the visitor, so the Worker passes
  # the real signal under X-Kona-Client-*. Akismet, the notification email and the api's
  # rack-attack throttle read these, so the contact form can't be exercised locally without them.
  def contact_headers(env)
    headers = auth_headers
    headers["accept"] = env["HTTP_ACCEPT"] if env["HTTP_ACCEPT"]
    headers["content-type"] = env["CONTENT_TYPE"] if env["CONTENT_TYPE"]
    headers["x-kona-client-ip"] = env["REMOTE_ADDR"] if env["REMOTE_ADDR"]
    headers["x-kona-client-ua"] = env["HTTP_USER_AGENT"] if env["HTTP_USER_AGENT"]
    headers
  end

  # Status passes through verbatim: an empty 200 is the api's "no data" signal and must still
  # collapse the widget, and a non-2xx must still leave already-rendered content alone.
  # `no-store` is a deliberate local divergence from the production
  # `max-age=0, stale-while-revalidate=N`, so a reload always shows the render you just changed.
  def rack_response(response)
    headers = { "cache-control" => "no-store" }
    headers["content-type"] = response.headers["content-type"] if response.headers["content-type"]
    # The no-JS contact path answers with a 303.
    headers["location"] = response.headers["location"] if response.headers["location"]

    [ response.code, headers, [ response.body.to_s ] ]
  end

  # Mirrors the Worker's empty 502. The message is the only record of a misconfigured or
  # unreachable api — the widget itself just collapses, silently.
  def bad_gateway(message)
    warn "== DevApiProxy: #{message}"
    [ 502, { "cache-control" => "no-store" }, [ "" ] ]
  end
end

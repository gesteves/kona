# The rate limits and the abuse control for the fly.io origin, which a constant group of
# vulnerability scanners reads directly.
#
# ⚠️ Never ban an IP. All the correct /widgets/* traffic comes through the Worker proxy of the web
# app, from a small shared set of egress IPs. Thus one scanner through that proxy would ban a
# shared address and 403 each visitor at the same time. For that reason:
#   * the blocklist matches only path patterns, and never an IP, and
#   * the throttle uses the client IP as its key, but it applies only outside the known route
#     prefixes. Thus the proxy traffic for a widget never gets a throttle.
#
# The rules do not apply in the test environment, but they stay registered. Thus a spec can use
# them when it sets Rack::Attack.enabled.

require "cgi"

Rack::Attack.enabled = !Rails.env.test?

Rack::Attack.cache.store =
  if Rails.env.test?
    ActiveSupport::Cache::MemoryStore.new
  else
    ActiveSupport::Cache::RedisCacheStore.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379"))
  end

# The prefixes of the true routes of the app. Each path outside them is a probe. `/assets` belongs
# to Propshaft and Rails does not draw it as a route, thus it needs an entry here. Both
# ActionDispatch::Static and Propshaft::Server are above this middleware (positions 3 and 4 against
# 29 — read `bin/rails middleware`), thus an asset request must not come here at all. This entry
# stops a throttle on such a request as a scanner probe, if one ever comes here.
RACK_ATTACK_KNOWN_PREFIXES = %w[/up /api /widgets /webhooks /whoop /sidekiq /signin /signout /auth /connected-apps /spam /location /republish /course-maps /share /assets].freeze
RACK_ATTACK_KNOWN_ROUTE = lambda do |path|
  path == "/" || RACK_ATTACK_KNOWN_PREFIXES.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
end

# The clear targets of a scanner: dot files and secret stores, CMS and admin probes, script
# extensions, and the framework status endpoints that this app does not have.
#
# ⚠️ `.well-known` is not in the dot-file group, on purpose. It is the standard place for correct
# endpoints, and a 403 for all of them would stop a future endpoint in a way that looks like a zone
# problem. A probe to it goes to the 404 catch-all, which costs the same.
RACK_ATTACK_PROBE_PATTERN = %r{
  (^|/)\.(env|git|aws|ssh|htaccess|svn)  # dotfiles & secret stores
  | /wp-(login|admin|content|includes)   # WordPress
  | \.(php|asp|aspx|jsp|cgi)(/|$|\?)      # script extensions
  | /(actuator|phpmyadmin|pma|adminer)    # admin panels
  | /api/(secrets|config|debug|env|keys|status|version|health|v\d+/config) # config/secret probes
}xi

# Tells if a path looks like a scanner probe. A scanner writes the important characters as percent
# escapes, to go past a simple match. Thus the code also tests a decoded copy. An escape sequence
# with an incorrect shape is not a probe: it gets a 404 or a throttle.
RACK_ATTACK_PROBE_PATH = lambda do |path|
  return true if RACK_ATTACK_PROBE_PATTERN.match?(path)
  decoded = CGI.unescape(path).scrub
  decoded != path && RACK_ATTACK_PROBE_PATTERN.match?(decoded)
rescue ArgumentError
  false
end

# Finds the true client IP, and it reads the nearest proxy first. Two proxies are in front: behind
# Cloudflare, Fly-Client-IP is a PoP and not the visitor, thus CF-Connecting-IP is the correct one.
#
# ⚠️ Anything that reaches the fly origin directly can write a false CF-Connecting-IP. Thus it can
# be the key of the throttle below, where a false header gives at most a 429 on a request that
# would give a 404. But it must never control a ban.
class Rack::Attack::Request < ::Rack::Request
  def client_ip
    @client_ip ||= get_header("HTTP_CF_CONNECTING_IP").presence ||
                   get_header("HTTP_FLY_CLIENT_IP").presence ||
                   ip
  end
end

# Blocks each probe path, by the path and never by the IP. It stops them before the routing.
Rack::Attack.blocklist("probe-paths") do |req|
  RACK_ATTACK_PROBE_PATH.call(req.path)
end

# Throttles a client that makes many requests to paths outside the known routes. The exclusion of
# the known prefixes is what keeps a throttle off the shared proxy IPs.
Rack::Attack.throttle("unknown-paths/ip", limit: 20, period: 1.minute) do |req|
  req.client_ip unless RACK_ATTACK_KNOWN_ROUTE.call(req.path)
end

# Throttles the sign-in pages. The admin host is the one host where client_ip is a safe key:
# nothing reaches it through the widget proxy, thus there is no shared egress that would throttle
# each person at the same time. Both paths are in RACK_ATTACK_KNOWN_PREFIXES, which is what keeps
# them out of the throttle above. Without this rule the login pages have no limit at the origin.
#
# ⚠️ This is a throttle, and never a blocklist. That is the rule at the top of this file. The limit
# is high, because Google does the true authentication and a 429 on your own sign-in is worse than
# a slow attacker.
Rack::Attack.throttle("signin/ip", limit: 30, period: 5.minutes) do |req|
  req.client_ip if req.path == "/signin" || req.path.start_with?("/auth/")
end

# Throttles the contact-form submissions for each visitor. The key is the IP that the web proxy
# sends, and not client_ip. For proxy traffic, client_ip is the shared egress, and it would
# throttle each person at the same time. A direct request to the origin has no forwarded header and
# has no key here. A bearer token already controls it.
Rack::Attack.throttle("contact/ip", limit: 5, period: 1.hour) do |req|
  req.get_header("HTTP_X_KONA_CLIENT_IP").presence if req.post? && req.path == "/api/contact"
end

# Plain-text responses, as in lib/plain_text_exceptions.rb. There are no edge cache headers,
# because an error must never stay in the edge cache.
RACK_ATTACK_PLAIN_TEXT = { "content-type" => "text/plain; charset=utf-8" }.freeze

Rack::Attack.blocklisted_responder = ->(_req) { [ 403, RACK_ATTACK_PLAIN_TEXT.dup, [ "403 Forbidden\n" ] ] }
Rack::Attack.throttled_responder   = ->(_req) { [ 429, RACK_ATTACK_PLAIN_TEXT.dup, [ "429 Too Many Requests\n" ] ] }

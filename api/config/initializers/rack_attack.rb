# Rate limiting and abuse mitigation for the fly.io origin, which is hit directly by a steady
# stream of vulnerability scanners.
#
# ⚠️ Never ban by IP. All legitimate /widgets/* traffic arrives through the web app's Worker
# proxy from a small shared set of egress IPs, so one scanner probing through that proxy would
# ban a shared address and 403 every visitor at once. Hence:
#   * the blocklist matches path patterns only, never IPs, and
#   * the throttle keys on the client IP but applies only outside the known route prefixes, so
#     proxied widget traffic is never throttled.
#
# Enforcement is off in the test env, but the rules stay registered so specs can exercise them
# by flipping Rack::Attack.enabled.

require "cgi"

Rack::Attack.enabled = !Rails.env.test?

Rack::Attack.cache.store =
  if Rails.env.test?
    ActiveSupport::Cache::MemoryStore.new
  else
    ActiveSupport::Cache::RedisCacheStore.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379"))
  end

# Prefixes of the app's real routes. Anything outside these is, by definition, a probe.
RACK_ATTACK_KNOWN_PREFIXES = %w[/up /api /widgets /webhooks /whoop /sidekiq /login /logout /auth].freeze
RACK_ATTACK_KNOWN_ROUTE = lambda do |path|
  path == "/" || RACK_ATTACK_KNOWN_PREFIXES.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
end

# Obvious scanner targets: dotfiles and secret stores, CMS/admin probes, script extensions, and
# framework status endpoints this app doesn't expose.
#
# ⚠️ `.well-known` is deliberately not in the dotfile group — it's the standard home of
# legitimate endpoints, and a blanket 403 would break a future one in a way that looks like a
# zone problem. Probes to it fall through to the 404 catch-all, which is equally cheap.
RACK_ATTACK_PROBE_PATTERN = %r{
  (^|/)\.(env|git|aws|ssh|htaccess|svn)  # dotfiles & secret stores
  | /wp-(login|admin|content|includes)   # WordPress
  | \.(php|asp|aspx|jsp|cgi)(/|$|\?)      # script extensions
  | /(actuator|phpmyadmin|pma|adminer)    # admin panels
  | /api/(secrets|config|debug|env|keys|status|version|health|v\d+/config) # config/secret probes
}xi

# Whether a path looks like a scanner probe. Scanners percent-encode the giveaway characters to
# dodge naive matching, so a decoded copy is tested too. A malformed sequence isn't treated as a
# probe; it'll 404 or get throttled instead.
RACK_ATTACK_PROBE_PATH = lambda do |path|
  return true if RACK_ATTACK_PROBE_PATTERN.match?(path)
  decoded = CGI.unescape(path).scrub
  decoded != path && RACK_ATTACK_PROBE_PATTERN.match?(decoded)
rescue ArgumentError
  false
end

# Resolves the real client IP, innermost proxy first. Two proxies sit in front: behind
# Cloudflare, Fly-Client-IP is a PoP rather than the visitor, so CF-Connecting-IP wins.
#
# ⚠️ CF-Connecting-IP is forgeable by anything hitting the fly origin directly, so it may key
# the throttle below — where the worst a forged header buys is a 429 on a request that would
# 404 anyway — but must never gate a ban.
class Rack::Attack::Request < ::Rack::Request
  def client_ip
    @client_ip ||= get_header("HTTP_CF_CONNECTING_IP").presence ||
                   get_header("HTTP_FLY_CLIENT_IP").presence ||
                   ip
  end
end

# Blocks probe paths outright, by path and never by IP, shedding them before routing.
Rack::Attack.blocklist("probe-paths") do |req|
  RACK_ATTACK_PROBE_PATH.call(req.path)
end

# Throttles a client hammering paths outside the known routes. Excluding the known prefixes is
# what keeps the shared proxy IPs from ever being throttled.
Rack::Attack.throttle("unknown-paths/ip", limit: 20, period: 1.minute) do |req|
  req.client_ip unless RACK_ATTACK_KNOWN_ROUTE.call(req.path)
end

# Throttles contact-form submissions per visitor, keyed on the IP the web proxy forwards rather
# than client_ip — which for proxied traffic is the shared egress, and would throttle everyone
# at once. A direct origin hit carries no forwarded header and isn't keyed here; it's already
# bearer-gated.
Rack::Attack.throttle("contact/ip", limit: 5, period: 1.hour) do |req|
  req.get_header("HTTP_X_KONA_CLIENT_IP").presence if req.post? && req.path == "/api/contact"
end

# Plain-text responses matching lib/plain_text_exceptions.rb. No edge cache headers: an error
# must never be pinned at the edge.
RACK_ATTACK_PLAIN_TEXT = { "content-type" => "text/plain; charset=utf-8" }.freeze

Rack::Attack.blocklisted_responder = ->(_req) { [403, RACK_ATTACK_PLAIN_TEXT.dup, ["403 Forbidden\n"]] }
Rack::Attack.throttled_responder   = ->(_req) { [429, RACK_ATTACK_PLAIN_TEXT.dup, ["429 Too Many Requests\n"]] }

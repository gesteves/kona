# Rate limiting / abuse mitigation for the fly.io origin.
#
# The origin is hit directly (bypassing the edge cache in front of it) by a steady stream of
# vulnerability scanners probing paths like /api/.env, /api/secrets, /wp-login.php, etc.
# This sheds that load by blocking known probe paths before they reach routing (which also
# keeps them out of the logs).
#
# Design note — all LEGITIMATE /widgets/* traffic arrives through the web app's Worker proxy
# from a small, shared set of egress IPs (and behind fly's proxy a single request's source IP can
# resolve to a shared fly load-balancer address). A per-IP BAN is therefore dangerous: one
# scanner probing a path through the public proxy would ban a shared IP and 403 every visitor
# at once.
# So:
#   * the blocklist matches PATH PATTERNS only (IP-agnostic) — it blocks the probe request
#     itself, never bans an IP across paths, so it can't take down shared-IP traffic, and
#   * the throttle keys on the real client IP (see client_ip below) but applies ONLY to requests
#     outside the known route prefixes, so proxied widget traffic is never throttled.
#
# Enforcement is disabled in the test env (so the suite isn't rate-limited); the rules are still
# registered so specs can exercise them by flipping Rack::Attack.enabled. Counters live in the
# shared Redis in real environments and in memory under test.

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

# Obvious scanner targets: dotfiles/secrets, common CMS/admin probes, script extensions,
# and framework status/config endpoints we don't expose.
#
# ⚠️ `.well-known` is deliberately NOT in the dotfile group: it's the standard home of
# legitimate endpoints (security.txt, did:web, OAuth metadata), and a blanket 403 here would
# silently break a future one in a way that looks like a Cloudflare/zone problem. Probes to it
# just fall through to the plain-text 404 catch-all, which is equally cheap.
RACK_ATTACK_PROBE_PATTERN = %r{
  (^|/)\.(env|git|aws|ssh|htaccess|svn)  # dotfiles & secret stores
  | /wp-(login|admin|content|includes)   # WordPress
  | \.(php|asp|aspx|jsp|cgi)(/|$|\?)      # script extensions
  | /(actuator|phpmyadmin|pma|adminer)    # admin panels
  | /api/(secrets|config|debug|env|keys|status|version|health|v\d+/config) # config/secret probes
}xi

# Whether a path looks like a scanner probe. Scanners percent-encode the giveaway characters
# (e.g. /app/%2Eenv for /app/.env) to dodge naive matching, and req.path keeps that encoding, so
# test a decoded copy too. Guarded so a malformed %-sequence or invalid byte can't raise (it just
# isn't treated as a probe — it'll 404 / get throttled instead).
RACK_ATTACK_PROBE_PATH = lambda do |path|
  return true if RACK_ATTACK_PROBE_PATTERN.match?(path)
  decoded = CGI.unescape(path).scrub
  decoded != path && RACK_ATTACK_PROBE_PATTERN.match?(decoded)
rescue ArgumentError
  false
end

# Resolve the real client IP, innermost proxy first.
#
# There can be two proxies in front of us. The zone is proxied through Cloudflare, so for any
# request that came that way fly sees a CLOUDFLARE edge node as its client: Fly-Client-IP is the
# PoP, not the visitor, and every distinct client collapses onto a handful of addresses — the
# "per-IP rule is effectively global" failure the design note above warns about. Cloudflare puts
# the true client in CF-Connecting-IP, so prefer it. Fall back to Fly-Client-IP for requests that
# reach fly without passing through Cloudflare (and to Rack's own #ip in dev/test).
#
# Trust note: CF-Connecting-IP is only unspoofable on traffic that actually traversed Cloudflare;
# a client hitting the fly origin directly could forge it. We accept that here because the only
# thing keyed on this IP is the throttle below, which applies solely to paths OUTSIDE the known
# route prefixes — so the worst a forged header buys is a 429 on requests that would 404 anyway.
# It must NOT be used for anything that bans, and per the design note nothing bans by IP.
class Rack::Attack::Request < ::Rack::Request
  def client_ip
    @client_ip ||= get_header("HTTP_CF_CONNECTING_IP").presence ||
                   get_header("HTTP_FLY_CLIENT_IP").presence ||
                   ip
  end
end

# Block obvious scanner probe paths outright — matched by PATH, never by IP (see the design note
# above: an IP ban would 403 the shared proxy/LB IPs that all real traffic shares). Blocking the
# matching request sheds the probe before it reaches routing, with zero false positives.
Rack::Attack.blocklist("probe-paths") do |req|
  RACK_ATTACK_PROBE_PATH.call(req.path)
end

# Safety net: throttle a single client hammering paths outside the known routes. Keyed on the real
# client IP and excluding the known prefixes (incl. /widgets/*) by construction, so the shared
# proxy IPs are never throttled.
Rack::Attack.throttle("unknown-paths/ip", limit: 20, period: 1.minute) do |req|
  req.client_ip unless RACK_ATTACK_KNOWN_ROUTE.call(req.path)
end

# Throttle contact-form submissions per real visitor. Keyed on the IP the web proxy forwards
# (X-Kona-Client-IP) — NOT client_ip, which for proxied traffic is the shared proxy egress, so
# keying the contact form on it would throttle every visitor at once. Safe by the rules above: a
# throttle (429), never a ban, keyed on the true per-visitor IP and scoped to this one path, so it
# can't 403 the shared proxy IPs or touch /widgets/*. A direct origin hit (no forwarded header) is
# not keyed here — it's already bearer-gated.
Rack::Attack.throttle("contact/ip", limit: 5, period: 1.hour) do |req|
  req.get_header("HTTP_X_KONA_CLIENT_IP").presence if req.post? && req.path == "/api/contact"
end

# Plain-text responses matching lib/plain_text_exceptions.rb. No edge cache headers — errors
# must never be pinned at the edge.
RACK_ATTACK_PLAIN_TEXT = { "content-type" => "text/plain; charset=utf-8" }.freeze

Rack::Attack.blocklisted_responder = ->(_req) { [403, RACK_ATTACK_PLAIN_TEXT.dup, ["403 Forbidden\n"]] }
Rack::Attack.throttled_responder   = ->(_req) { [429, RACK_ATTACK_PLAIN_TEXT.dup, ["429 Too Many Requests\n"]] }

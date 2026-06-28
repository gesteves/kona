# Rate limiting / abuse mitigation for the fly.io origin.
#
# The origin is hit directly (bypassing the Netlify edge cache) by a steady stream of
# vulnerability scanners probing paths like /api/.env, /api/secrets, /wp-login.php, etc.
# This sheds that load by blocking known probe paths before they reach routing (which also
# keeps them out of the logs).
#
# Design note — all LEGITIMATE /api/* traffic arrives through the Netlify proxy from a small,
# shared set of egress IPs (and behind fly's proxy a single request's source IP can resolve to
# a shared fly load-balancer address). A per-IP BAN is therefore dangerous: one scanner probing
# an /api/* path through the public proxy would ban a shared IP and 403 every visitor at once.
# So:
#   * the blocklist matches PATH PATTERNS only (IP-agnostic) — it blocks the probe request
#     itself, never bans an IP across paths, so it can't take down shared-IP traffic, and
#   * the throttle keys on the real client IP (Fly-Client-IP) but applies ONLY to requests
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
RACK_ATTACK_KNOWN_PREFIXES = %w[/up /api /whoop /sidekiq].freeze
RACK_ATTACK_KNOWN_ROUTE = lambda do |path|
  path == "/" || RACK_ATTACK_KNOWN_PREFIXES.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
end

# Obvious scanner targets: dotfiles/secrets, common CMS/admin probes, script extensions,
# and framework status/config endpoints we don't expose.
RACK_ATTACK_PROBE_PATTERN = %r{
  (^|/)\.(env|git|aws|ssh|htaccess|svn|well-known)  # dotfiles & secret stores
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

# Resolve the real client IP. Behind fly's proxy, Rack's own Request#ip can resolve to a shared
# fly load-balancer address — which would make any per-IP rule effectively global — so prefer the
# Fly-Client-IP header fly sets to the true client.
class Rack::Attack::Request < ::Rack::Request
  def client_ip
    @client_ip ||= get_header("HTTP_FLY_CLIENT_IP").presence || ip
  end
end

# Block obvious scanner probe paths outright — matched by PATH, never by IP (see the design note
# above: an IP ban would 403 the shared proxy/LB IPs that all real traffic shares). Blocking the
# matching request sheds the probe before it reaches routing, with zero false positives.
Rack::Attack.blocklist("probe-paths") do |req|
  RACK_ATTACK_PROBE_PATH.call(req.path)
end

# Safety net: throttle a single client hammering paths outside the known routes. Keyed on the real
# client IP and excluding the known prefixes (incl. /api/*) by construction, so the shared proxy
# IPs are never throttled.
Rack::Attack.throttle("unknown-paths/ip", limit: 20, period: 1.minute) do |req|
  req.client_ip unless RACK_ATTACK_KNOWN_ROUTE.call(req.path)
end

# Plain-text responses matching lib/plain_text_exceptions.rb. No durable cache headers — the
# Netlify proxy only forwards edge headers on 2xx, so these are never pinned at the edge.
RACK_ATTACK_PLAIN_TEXT = { "content-type" => "text/plain; charset=utf-8" }.freeze

Rack::Attack.blocklisted_responder = ->(_req) { [403, RACK_ATTACK_PLAIN_TEXT.dup, ["403 Forbidden\n"]] }
Rack::Attack.throttled_responder   = ->(_req) { [429, RACK_ATTACK_PLAIN_TEXT.dup, ["429 Too Many Requests\n"]] }

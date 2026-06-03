# Rate limiting / abuse mitigation for the fly.io origin.
#
# The origin is hit directly (bypassing the Netlify edge cache) by a steady stream of
# vulnerability scanners probing paths like /api/.env, /api/secrets, /wp-login.php, etc.
# This sheds that load and stops repeat offenders from reaching routing at all (which also
# keeps them out of the logs).
#
# Design note — all LEGITIMATE /api/* traffic arrives through the Netlify proxy from a small,
# shared set of egress IPs. A blanket per-IP throttle would therefore throttle real users, so:
#   * the blocklist matches PATH PATTERNS (IP-agnostic, no false positives — real traffic only
#     ever hits the known routes), and
#   * the throttle keys on IP but applies ONLY to requests outside the known route prefixes,
#     so proxied widget traffic is never throttled regardless of source IP.
#
# Enforcement is disabled in the test env (so the suite isn't rate-limited); the rules are still
# registered so specs can exercise them by flipping Rack::Attack.enabled. Counters live in the
# shared Redis in real environments and in memory under test.

Rack::Attack.enabled = !Rails.env.test?

Rack::Attack.cache.store =
  if Rails.env.test?
    ActiveSupport::Cache::MemoryStore.new
  else
    ActiveSupport::Cache::RedisCacheStore.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379"))
  end

# Prefixes of the app's real routes. Anything outside these is, by definition, a probe.
RACK_ATTACK_KNOWN_PREFIXES = %w[/up /api /whoop].freeze
RACK_ATTACK_KNOWN_ROUTE = lambda do |path|
  path == "/" || RACK_ATTACK_KNOWN_PREFIXES.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
end

# Obvious scanner targets: dotfiles/secrets, common CMS/admin probes, script extensions,
# and framework status/config endpoints we don't expose.
RACK_ATTACK_PROBE_PATTERN = %r{
  (^|/)\.(env|git|aws|ssh|htaccess|svn)  # dotfiles & secret stores
  | /wp-(login|admin|content|includes)   # WordPress
  | \.(php|asp|aspx|jsp|cgi)(/|$|\?)      # script extensions
  | /(actuator|phpmyadmin|pma|adminer)    # admin panels
  | /api/(secrets|config|debug|env|keys|status|version|health|v\d+/config) # config/secret probes
}xi

# Ban IPs that repeatedly hit obvious probe paths. Once banned they get a flat 403 at the
# middleware and never reach routing (so no ActionController::RoutingError log noise either).
Rack::Attack.blocklist("probe-fail2ban") do |req|
  Rack::Attack::Fail2Ban.filter("probes-#{req.ip}", maxretry: 3, findtime: 10.minutes, bantime: 1.hour) do
    RACK_ATTACK_PROBE_PATTERN.match?(req.path)
  end
end

# Safety net: throttle any single IP hammering paths outside the known routes. Generous, and
# excludes legitimate /api/* traffic by construction (so the shared proxy IPs are never hit).
Rack::Attack.throttle("unknown-paths/ip", limit: 20, period: 1.minute) do |req|
  req.ip unless RACK_ATTACK_KNOWN_ROUTE.call(req.path)
end

# Plain-text responses matching lib/plain_text_exceptions.rb. No durable cache headers — the
# Netlify proxy only forwards edge headers on 2xx, so these are never pinned at the edge.
RACK_ATTACK_PLAIN_TEXT = { "content-type" => "text/plain; charset=utf-8" }.freeze

Rack::Attack.blocklisted_responder = ->(_req) { [403, RACK_ATTACK_PLAIN_TEXT.dup, ["403 Forbidden\n"]] }
Rack::Attack.throttled_responder   = ->(_req) { [429, RACK_ATTACK_PLAIN_TEXT.dup, ["429 Too Many Requests\n"]] }

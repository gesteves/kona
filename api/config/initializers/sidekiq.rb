require "sidekiq/web"

# Sidekiq's queues live in the API's own Redis, the same REDIS_URL the cache uses. Pinned
# explicitly, though Sidekiq would default to it, to mirror config/initializers/redis.rb.
redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379")

# ⚠️ The server and client read timeouts are deliberately different — don't collapse them into
# one shared hash. The fetch loop wants to be patient; enqueueing wants to fail fast.
#
# Server: the fetch loop is a BRPOP with a 2s server-side timeout, and redis-client adds the
# read timeout on top rather than racing it, so Sidekiq's default 3 gives a 5s budget for a
# reply due in 2 — tight enough that ordinary CPU steal on a shared-cpu machine raises out of
# the fetch loop. Widening to 10 makes the window 12s, absorbing blips without hiding a real
# outage, since an unreachable Redis raises CannotConnectError and still reports immediately.
# (See lib/sidekiq_redis_timeout_filter.rb, which drops the reports this still produces.)
#
# Client: runs inside Puma, where several endpoints enqueue in-request, so a long timeout would
# turn a Redis stall into a hung request against the 20s rack-timeout budget.
Sidekiq.configure_server { |config| config.redis = { url: redis_url, timeout: 10 } }
Sidekiq.configure_client { |config| config.redis = { url: redis_url } }

# Gates the Sidekiq web UI behind the owner session set by Google sign-in. It's a Rack app
# rather than a Rails controller, but it's mounted downstream of the session middleware, so the
# session is in env["rack.session"]. Defined inline to avoid autoload-at-boot ordering issues.
class SidekiqOwnerGuard
  def initialize(app)
    @app = app
  end

  def call(env)
    session = env["rack.session"]
    owner = ENV["OWNER_EMAIL"].to_s
    return @app.call(env) if owner.present? && session && session["owner_email"] == owner

    [ 302, { "location" => "/signin" }, [] ]
  end
end

Sidekiq::Web.use SidekiqOwnerGuard

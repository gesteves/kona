require "sidekiq/web"

# Sidekiq stores its queues in the API's own Redis (the dedicated kona-redis instance in
# production), the same REDIS_URL the cache uses. Sidekiq defaults to REDIS_URL, but pin it
# explicitly to mirror config/initializers/redis.rb and keep the source of truth obvious.
redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379")

# ⚠️ The server and client read timeouts are deliberately different — don't collapse them back
# into one shared hash.
#
# SERVER (the Sidekiq worker process). Its fetch loop is a BRPOP with a 2s server-side timeout
# (Sidekiq::BasicFetch::TIMEOUT), and redis-client doesn't race that against the socket deadline —
# it adds the configured read timeout on top (`connection_timeout` = `timeout + read_timeout`,
# redis_client/connection_mixin.rb). At Sidekiq's default timeout of 3 that's a 5-second budget
# for a reply that should arrive in 2, so any transient stall — CPU steal on either shared-cpu-1x
# machine, a GC pause on the worker, a 6PN blip — raises
# RedisClient::ReadTimeoutError("Waited 5 seconds") out of the fetch loop.
#
# Sidekiq handles that correctly on its own (report once, sleep 1s, retry, log "Redis is online"
# on recovery — Sidekiq::Processor#handle_fetch_exception), so nothing is lost and no job is
# affected. But `@down` is per-Processor and config/sidekiq.yml sets concurrency 5, so a single
# blip produces up to five Bugsnag reports. Widening the server's read timeout to 10 makes the
# fetch window 12s, which absorbs the blips without hiding a real outage: a Redis that's actually
# unreachable raises CannotConnectError, which still reports immediately.
#
# CLIENT stays at Sidekiq's default 3. It runs inside the Puma process — the Contentful and Whoop
# webhooks, POST /api/location, POST /api/contact and POST /api/build all enqueue in-request — so a
# 10s timeout there would turn a Redis stall into a hung request (RACK_TIMEOUT_SERVICE_TIMEOUT is
# 20). Enqueueing wants to fail fast; the fetch loop wants to be patient.
Sidekiq.configure_server { |config| config.redis = { url: redis_url, timeout: 10 } }
Sidekiq.configure_client { |config| config.redis = { url: redis_url } }

# Gate the web UI behind the owner session set by Google sign-in (SessionsController). Sidekiq's
# web app is a Rack app, not a Rails controller, but it's mounted downstream of the session
# middleware, so the Rails session is in env["rack.session"]. Unauthenticated hits redirect to
# /login. Defined inline to avoid autoload-at-boot ordering concerns.
class SidekiqOwnerGuard
  def initialize(app)
    @app = app
  end

  def call(env)
    session = env["rack.session"]
    owner = ENV["OWNER_EMAIL"].to_s
    return @app.call(env) if owner.present? && session && session["owner_email"] == owner

    [302, { "location" => "/login" }, []]
  end
end

Sidekiq::Web.use SidekiqOwnerGuard

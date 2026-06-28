require "sidekiq/web"

# Sidekiq stores its queues in the API's own Redis (the dedicated kona-redis instance in
# production), the same REDIS_URL the cache uses. Sidekiq defaults to REDIS_URL, but pin it
# explicitly to mirror config/initializers/redis.rb and keep the source of truth obvious.
redis_config = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379") }

Sidekiq.configure_server { |config| config.redis = redis_config }
Sidekiq.configure_client { |config| config.redis = redis_config }

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

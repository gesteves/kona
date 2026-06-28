require "sidekiq/web"

# Sidekiq stores its queues in the API's own Redis (the dedicated kona-redis instance in
# production), the same REDIS_URL the cache uses. Sidekiq defaults to REDIS_URL, but pin it
# explicitly to mirror config/initializers/redis.rb and keep the source of truth obvious.
redis_config = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379") }

Sidekiq.configure_server { |config| config.redis = redis_config }
Sidekiq.configure_client { |config| config.redis = redis_config }

# Gate the web UI behind the same owner HTTP Basic Auth as the Whoop OAuth flow (for now).
# The block runs per-request, so OwnerBasicAuth resolves at request time (autoloaded).
Sidekiq::Web.use(Rack::Auth::Basic, "Sidekiq") do |username, password|
  OwnerBasicAuth.valid?(username, password)
end

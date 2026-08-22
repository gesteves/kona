require "sidekiq/web"
# Adds the "Recurring Jobs" tab of sidekiq-scheduler to that dashboard: the schedule, the last run
# of each job, and a button that adds a job to the queue. This must come after sidekiq/web, and the
# same SidekiqOwnerGuard below controls it.
require "sidekiq-scheduler/web"

# The Sidekiq queues are in the Redis of the API, at the same REDIS_URL as the cache. This code sets
# it, although Sidekiq would use it by default, to be the same as config/initializers/redis.rb.
redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379")

# ⚠️ The read timeout of the server and the read timeout of the client are different, on purpose. Do
# not put them in one shared hash. The fetch loop must wait; a job that goes into the queue must fail
# quickly.
#
# The server: the fetch loop is a BRPOP with a 2s timeout on the server, and redis-client adds its
# read timeout to that time and does not run the two at the same time. Thus the Sidekiq default of 3
# gives a 5s budget for a reply that comes in 2s. That is short, and ordinary CPU competition on a
# shared-cpu machine then raises out of the fetch loop. A value of 10 makes the window 12s, which
# accepts a short problem and does not hide a true failure, because a Redis that the code cannot
# reach raises CannotConnectError and still reports immediately. Refer to
# lib/sidekiq_redis_timeout_filter.rb, which removes the reports that this still makes.
#
# The client: this runs in Puma, where more than one endpoint adds a job to the queue during a
# request. Thus a long timeout would make a Redis delay into a request that stops, against the 20s
# rack-timeout budget.
Sidekiq.configure_server { |config| config.redis = { url: redis_url, timeout: 10 } }
Sidekiq.configure_client { |config| config.redis = { url: redis_url } }

# The owner session from the Google sign-in controls the Sidekiq web UI. That UI is a Rack app and
# not a Rails controller, but it is below the session middleware. Thus the session is in
# env["rack.session"]. This code is here, and not in another file, to prevent an autoload order
# problem at the start.
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

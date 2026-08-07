require "redis"
require "connection_pool"

# Shared Redis client, using the same REDIS_URL credentials as the web app.
#
# ⚠️ Pooled, not a single client. redis-rb wraps every command in a Monitor, so one shared
# instance is thread-safe but *serializes* every command across all of them — the Puma threads,
# the Sidekiq workers, and the parallel upstream fan-out in the widget controllers all queue
# behind each other, and with a 3s read timeout one slow command stalls the lot.
#
# ConnectionPool::Wrapper (not ConnectionPool) is deliberate: it delegates method calls straight
# through, so every existing `$redis.get` / `$redis.setex` call site keeps working without a
# `.with { }` block. Each call checks a connection out and back.
#
# Sized for the widest consumer — Sidekiq's concurrency — since both processes load this file.
REDIS_POOL_SIZE = Integer(ENV.fetch("REDIS_POOL_SIZE", 10))

$redis ||= ConnectionPool::Wrapper.new(size: REDIS_POOL_SIZE, timeout: 5) do
  Redis.new(
    url: ENV["REDIS_URL"] || "redis://localhost:6379",
    connect_timeout: 5,
    read_timeout: 3,
    write_timeout: 3,
    reconnect_attempts: [0.1, 0.5, 1.0]
  )
end

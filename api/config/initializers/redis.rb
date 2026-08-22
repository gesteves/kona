require "redis"
require "connection_pool"

# The shared Redis client. It uses the same REDIS_URL credentials as the web app.
#
# ⚠️ This is a pool, and not one client. redis-rb puts each command in a Monitor, thus one shared
# instance is thread-safe but it runs each command in sequence, across all the threads. The Puma
# threads, the Sidekiq workers, and the parallel upstream calls in the widget controllers all wait
# for each other, and with a 3s read timeout one slow command stops all of them.
#
# This uses ConnectionPool::Wrapper, and not ConnectionPool, on purpose: the wrapper sends each
# method call through, thus each `$redis.get` and `$redis.setex` in the code still works with no
# `.with { }` block. Each call takes a connection and gives it back.
#
# The size is for the largest consumer, because both processes load this file. ⚠️ That is NOT the
# Sidekiq concurrency of 5. It is the web process: RAILS_MAX_THREADS requests, and each one calls
# ParallelUpstreams, which uses as many as 6 more threads in Widgets::WeatherController#current.
# Thus one weather request alone can need 7 connections. Each connection is short, because it is a
# GET, thus 10 makes the callers wait and does not raise, at a normal latency. Increase
# REDIS_POOL_SIZE if a checkout timeout appears.
REDIS_POOL_SIZE = Integer(ENV.fetch("REDIS_POOL_SIZE", 10))

$redis ||= ConnectionPool::Wrapper.new(size: REDIS_POOL_SIZE, timeout: 5) do
  Redis.new(
    url: ENV["REDIS_URL"] || "redis://localhost:6379",
    connect_timeout: 5,
    read_timeout: 3,
    write_timeout: 3,
    reconnect_attempts: [ 0.1, 0.5, 1.0 ]
  )
end

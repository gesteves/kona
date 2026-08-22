require "redis"

# The one owner of the shared $redis connection, which is the cache of the build. Thus the default
# URL and the timeouts are in one place. The name is RedisConnection, because the redis gem owns the
# name RedisClient.
module RedisConnection
  # @return [Redis] The shared connection. The code opens it at the first use.
  def self.connection
    $redis ||= Redis.new(
      url: ENV["REDIS_URL"] || "redis://localhost:6379",
      connect_timeout: 5,
      read_timeout: 3,
      write_timeout: 3,
      reconnect_attempts: [ 0.1, 0.5, 1.0 ]
    )
  end
end

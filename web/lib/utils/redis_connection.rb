require 'redis'

# Single owner of the shared $redis connection (the build-time cache). The Rakefile, the
# CacheHelpers helper, and the Font Awesome GraphQL client all go through this factory so
# the URL fallback and timeouts live in one place. (Named RedisConnection because the redis
# gem already owns the RedisClient constant.)
module RedisConnection
  def self.connection
    $redis ||= Redis.new(
      url: ENV['REDIS_URL'] || 'redis://localhost:6379',
      connect_timeout: 5,
      read_timeout: 3,
      write_timeout: 3,
      reconnect_attempts: [0.1, 0.5, 1.0]
    )
  end
end

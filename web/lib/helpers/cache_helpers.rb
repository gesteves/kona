require_relative '../utils/redis_connection'

module CacheHelpers
  def redis
    RedisConnection.connection
  end
end

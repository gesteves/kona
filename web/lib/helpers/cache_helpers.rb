module CacheHelpers
  def redis
    $redis ||= Redis.new(
      url: ENV['REDIS_URL'] || 'redis://localhost:6379',
      connect_timeout: 5,
      read_timeout: 3,
      write_timeout: 3,
      reconnect_attempts: [0.1, 0.5, 1.0]
    )
  end
end

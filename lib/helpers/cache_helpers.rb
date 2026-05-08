module CacheHelpers
  def redis
    $redis ||= Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD'],
      connect_timeout: 5,
      read_timeout: 3,
      write_timeout: 3,
      reconnect_attempts: [0.1, 0.5, 1.0]
    )
  end
end

require 'dotenv/tasks'
require 'rake/clean'
require 'redis'

# Load utils first so SafeRedis is available when data files initialize $redis at load time.
Dir["lib/utils/*.rb"].each { |file| require_relative file }
Dir["lib/data/*.rb"].each { |file| require_relative file }

# Import tasks from lib/tasks
Dir.glob('lib/tasks/**/*.rake').each { |r| import r }

def initialize_redis
  $redis ||= SafeRedis.new(
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

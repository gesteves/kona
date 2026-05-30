require 'dotenv/tasks'
require 'rake/clean'
require 'redis'

# Require all Ruby files in the lib/data and lib/utils directories
Dir["lib/data/*.rb"].each { |file| require_relative file }
Dir["lib/utils/*.rb"].each { |file| require_relative file }

# Import tasks from lib/tasks
Dir.glob('lib/tasks/**/*.rake').each { |r| import r }

def initialize_redis
  $redis ||= Redis.new(
    url: ENV['REDIS_URL'] || 'redis://localhost:6379',
    connect_timeout: 5,
    read_timeout: 3,
    write_timeout: 3,
    reconnect_attempts: [0.1, 0.5, 1.0]
  )
end

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
    host: ENV['REDIS_HOST'] || 'localhost',
    port: ENV['REDIS_PORT'] || 6379,
    username: ENV['REDIS_USERNAME'],
    password: ENV['REDIS_PASSWORD']
  )
end

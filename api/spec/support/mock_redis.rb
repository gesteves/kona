# Replaces the shared Redis client with an in-memory copy, thus `rspec` needs no Redis server. Each
# example starts with an empty store.
#
# ⚠️ This replaces `$redis` only. rspec-sidekiq puts Sidekiq in fake mode, and
# config/initializers/rack_attack.rb uses a memory store in the test environment. A new Redis
# client in the app needs its own mock here, or the specs need a server again.
require "mock_redis"

$redis = MockRedis.new

RSpec.configure do |config|
  config.before { $redis.flushdb }
end

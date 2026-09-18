# Removes the Redis keys that make a social post safe to do more than one time, before each
# example.
#
# ⚠️ All of these live longer than one example on purpose. `AtProto#open_session` keeps a session,
# thus without this an example makes no `createSession` call and writes to the service URL of the
# example before it. Each `SocialPostJob` keeps a lock for each post of a thread, thus a second
# example that uses the same keys adds no job at all.
RSpec.configure do |config|
  config.before do
    keys = $redis.keys("#{AtProto::SESSION_KEY_PREFIX}*") +
           $redis.keys("bluesky:did:*") +
           $redis.keys("#{BlueskyPostJob::ENQUEUE_LOCK_PREFIX}*") +
           $redis.keys("#{MastodonPostJob::ENQUEUE_LOCK_PREFIX}*") +
           $redis.keys("#{ThreadsPostJob::ENQUEUE_LOCK_PREFIX}*")
    $redis.del(*keys) if keys.any?
  end
end

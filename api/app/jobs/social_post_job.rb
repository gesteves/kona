# The parent of the three jobs that post one post of a thread and then add the job of the next
# post. Each subclass names its own lock prefix in `ENQUEUE_LOCK_PREFIX`.
#
# ⚠️ There is one job for each post, and not one job for the whole thread. Thus a failure runs
# one post again, and never a post that already went out.
class SocialPostJob < ApplicationJob
  # How long the lock of one post stays. ⚠️ It is longer than the 24-hour retry window of
  # ApplicationJob, thus a late retry cannot add the same post a second time.
  ENQUEUE_LOCK_TTL = 36.hours.to_i

  private

  # Reads the photos of the post from Redis.
  #
  # ⚠️ No job discards the photos. Bluesky and Mastodon read the same keys, in no known order, thus
  # the TTL that `Admin::SocialController#keep_photos` sets removes them.
  # ⚠️ A photo that is gone fails the post for good, and it does not post the words alone. The
  # owner asked for a post with photos, and `volatile-lru` can remove a key at the memory cap.
  # @param post [Hash] One post of the payload. `photos` is `[{ "id" =>, "alt" => }, …]` or absent.
  # @param count [Integer] The number of posts of the thread.
  # @return [Array<Hash>] `[{ bytes:, width:, height:, alt: }, …]`.
  def load_photos(post, index, count)
    store = SocialPhotos.new

    Array(post["photos"]).map do |photo|
      stored = store.fetch(photo["id"].to_s)
      raise lost_photo(photo, index, count) if stored.nil?

      { bytes: stored[:image], width: stored[:width], height: stored[:height], alt: photo["alt"].to_s }
    end
  end

  # Checks that each photo of the post is still in Redis, and does not read the bytes. It is for a
  # network that GETs each photo from its URL. The rules of #load_photos apply.
  # @return [Array<Hash>] `[{ id:, alt: }, …]`.
  def photo_refs(post, index, count)
    store = SocialPhotos.new

    Array(post["photos"]).map do |photo|
      raise lost_photo(photo, index, count) unless store.exists?(photo["id"].to_s)

      { id: photo["id"].to_s, alt: photo["alt"].to_s }
    end
  end

  # @return [ApplicationJob::PermanentError]
  def lost_photo(photo, index, count)
    ApplicationJob::PermanentError.new("#{self.class.name}: post #{index + 1}/#{count} lost its photo #{photo['id']}")
  end

  # Adds the job of the next post, one time only.
  #
  # ⚠️ This enqueue is inside the job of the post above it. When the process dies after the enqueue
  # and before Sidekiq acknowledges the job, the retry does that post again. That is safe, because
  # each service keeps its post below the key. But the retry also adds the next job a second time,
  # and Threads has no idempotency on its side: two jobs for one key there are two true posts. The
  # key of the next post is the same across both attempts, thus it is the lock.
  # @param posts [Array<Hash>]
  # @param index [Integer] The post to add.
  # @param args [Array] The rest of the arguments of the next job, that is, its reply reference.
  def enqueue_next(posts, index, *args)
    post = posts[index]
    return if post.blank?

    # ⚠️ The key of the post is the lock, thus a post with none cannot take one. A fallback to the
    # index would make one key, `…:1`, that each thread shares, and the second post of each other
    # thread would then go away for 36 hours. `Admin::SocialController` always makes the keys.
    key = post["key"].presence
    return if key.blank?

    lock = "#{self.class::ENQUEUE_LOCK_PREFIX}#{key}"
    return unless $redis.set(lock, "1", nx: true, ex: ENQUEUE_LOCK_TTL)

    begin
      self.class.perform_async(posts, index, *args)
    rescue StandardError
      # ⚠️ Give the lock back. The lock is above the enqueue, thus a Redis failure here would leave
      # it for 36 hours. The retry of this job then posts again at the same key, finds the lock, and
      # succeeds with the rest of the thread never sent and nothing to report it.
      $redis.del(lock)
      raise
    end
  end
end

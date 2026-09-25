# The parent of the three jobs that post one post of a thread and then add the job of the next
# post. Each subclass names its own lock prefix in `ENQUEUE_LOCK_PREFIX`.
#
# ⚠️ **There is one job for each POST, and not one job for the whole thread.** Thus a failure runs
# **one** post again, and never a post that already went out. A job that posted the whole chain
# would, on a retry, go back to the top of it.
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
  # The report names the post and the photo.
  # @param post [Hash] One post of the payload. `photos` is `[{ "id" =>, "alt" => }, …]` or absent.
  # @param index [Integer]
  # @param count [Integer] The number of posts of the thread.
  # @return [Array<Hash>] `[{ bytes:, width:, height:, alt: }, …]`.
  def load_photos(post, index, count)
    store = SocialPhotos.new

    Array(post["photos"]).map do |photo|
      stored = store.fetch(photo["id"].to_s)
      if stored.nil?
        raise ApplicationJob::PermanentError,
              "#{self.class.name}: post #{index + 1}/#{count} lost its photo #{photo['id']}"
      end

      { bytes: stored[:image], width: stored[:width], height: stored[:height], alt: photo["alt"].to_s }
    end
  end

  # Adds the job of the next post, one time only.
  #
  # ⚠️ This enqueue is INSIDE the job of the post above it. When the process dies after the enqueue
  # and before Sidekiq acknowledges the job, the retry does that post again — which is safe, each
  # service keeps its post below the key — AND it adds the next job a second time. The tail of the
  # thread then goes out two times. Threads has no idempotency on its side, thus two jobs for one
  # key there are two true posts. The key of the next post is the thing that is the same across
  # both attempts, thus it is the lock.
  # @param posts [Array<Hash>]
  # @param index [Integer] The post to add.
  # @param args [Array] The rest of the arguments of the next job, that is, its reply reference.
  # @return [void]
  def enqueue_next(posts, index, *args)
    post = posts[index]
    return if post.blank?

    # ⚠️ The key of the post is the lock, thus a post with none cannot take one. A fallback to the
    # index would make one key — `…:1` — that EVERY thread shares, and the second post of each other
    # thread would then go away for 36 hours. `Admin::SocialController` always makes the keys.
    key = post["key"].presence
    return if key.blank?

    lock = "#{self.class::ENQUEUE_LOCK_PREFIX}#{key}"
    return unless $redis.set(lock, "1", nx: true, ex: ENQUEUE_LOCK_TTL)

    begin
      self.class.perform_async(posts, index, *args)
    rescue StandardError
      # ⚠️ Give the lock back. The lock is above the enqueue, thus a Redis failure here would leave
      # it for 36 hours: the retry of this job posts again at the same key, finds the lock, and
      # SUCCEEDS with the rest of the thread never sent and nothing to report it.
      $redis.del(lock)
      raise
    end
  end
end

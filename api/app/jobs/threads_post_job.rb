# Posts one post of a draft from the Social media page to Threads, then adds the job of the next
# one.
#
# ⚠️ **There is one job for each POST, and not one job for the whole thread.** Refer to
# BlueskyPostJob for the reason.
#
# ⚠️ You can do each attempt more than one time. Meta gives no idempotency header, thus
# `Threads#post!` keeps the id of the media container in Redis below `key`. A retry then publishes
# the container that it made already, in place of a second one.
class ThreadsPostJob < ApplicationJob
  # How long to wait before the reply that follows a post. ⚠️ Meta needs the parent to be ready
  # before it accepts a container that names it.
  REPLY_DELAY = 30.seconds
  # @param posts [Array<Hash>] `[{ "key" =>, "text" =>, "link" => }, …]`, the whole thread.
  # @param index [Integer] Which post of that list this job writes.
  # @param reply_to_id [String, nil] The media id of the post above, or nil for the first.
  def perform(posts, index = 0, reply_to_id = nil)
    post = posts[index]
    return if post.blank?

    # ⚠️ It logs BEFORE the request. A failure raises, thus without this line the report
    # names no post of the thread and a thread of five gives five reports that read alike.
    Rails.logger.info("ThreadsPostJob: posting #{index + 1}/#{posts.length}")

    # ⚠️ Threads attaches the link itself, thus this reads no og: tags either.
    posted = Threads.new.post!(text: post["text"], url: post["link"],
                               idempotency_key: post["key"], reply_to_id: reply_to_id)
    Rails.logger.info("ThreadsPostJob: posted #{index + 1}/#{posts.length} as #{posted}")

    # ⚠️ It WAITS before the next post, and the other two networks do not. Meta answered `500` for a
    # container whose `reply_to_id` named a post that it had just published: that post is not a
    # reply target yet. The delay is the fix, and it costs nothing that matters, because a thread
    # goes out over a minute in place of a second.
    self.class.perform_in(REPLY_DELAY, posts, index + 1, posted) if posts[index + 1]
  end
end

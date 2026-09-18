# Posts one post of a draft from the Social media page to Threads, then adds the job of the next
# one. Refer to SocialPostJob for the one-job-for-each-post rule and the enqueue lock.
#
# ⚠️ You can do each attempt more than one time. Meta gives no idempotency header, thus
# `Threads#post!` keeps the id of the media container in Redis below `key`. A retry then publishes
# the container that it made already, in place of a second one.
class ThreadsPostJob < SocialPostJob
  # The prefix of each lock key. `spec/support/at_proto_session.rb` removes these keys before each
  # example. ⚠️ Threads has no idempotency on its side, thus this lock is the one thing that stops
  # a second post below a key.
  ENQUEUE_LOCK_PREFIX = "threads:thread:".freeze

  # @param posts [Array<Hash>] `[{ "key" =>, "text" =>, "link" => }, …]`, the whole thread. ⚠️ Each holds the
  #   same `"topic"`, when the owner gave one.
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
                               idempotency_key: post["key"], reply_to_id: reply_to_id,
                               topic: post["topic"])
    Rails.logger.info("ThreadsPostJob: posted #{index + 1}/#{posts.length} as #{posted}")

    # ⚠️ It adds the next post at once. A delay of 30 seconds went in here for a `500` on a reply
    # container, on the reasoning that Meta was not ready for the parent. **That was wrong**: the
    # delay changed nothing, and the token in the query string was the difference. Do not add a
    # wait here again without evidence for it.
    enqueue_next(posts, index + 1, posted)
  end
end

# Posts one post of a draft from the Social media page to Mastodon, then adds the job of the next
# one.
#
# ⚠️ **There is one job for each POST, and not one job for the whole thread.** Refer to
# BlueskyPostJob for the reason.
#
# ⚠️ You can do each attempt more than one time. `key` goes in the `Idempotency-Key` header, and the
# instance then answers with the status that it made already. That window is not for ever, thus the
# service also keeps the status in Redis for the length of the retries.
class MastodonPostJob < ApplicationJob
  # @param posts [Array<Hash>] `[{ "key" =>, "text" =>, "link" => }, …]`, the whole thread.
  # @param index [Integer] Which post of that list this job writes.
  # @param in_reply_to_id [String, nil] The id of the status above, or nil for the first.
  def perform(posts, index = 0, in_reply_to_id = nil)
    post = posts[index]
    return if post.blank?

    # ⚠️ It logs BEFORE the request. A failure raises, thus without this line the report
    # names no post of the thread and a thread of five gives five reports that read alike.
    Rails.logger.info("MastodonPostJob: posting #{index + 1}/#{posts.length}")

    # ⚠️ Mastodon renders the link inline and makes its own preview card, thus this reads no og:
    # tags at all.
    status = Mastodon.new.post!(text: post["text"], url: post["link"],
                                idempotency_key: post["key"], in_reply_to_id: in_reply_to_id)
    Rails.logger.info("MastodonPostJob: posted #{index + 1}/#{posts.length} at #{status['url']}")

    return if posts[index + 1].blank?

    # ⚠️ A reply names the status above it by its id. With no id, the next post would go out as a
    # new toot and not as a reply, with no message.
    raise "Mastodon gave no status id for post #{index + 1}, thus the thread cannot continue" if status["id"].blank?

    self.class.perform_async(posts, index + 1, status["id"])
  end
end

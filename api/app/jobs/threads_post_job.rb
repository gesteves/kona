# Posts one draft from the Share page to Threads.
#
# ⚠️ You can do this job more than one time. Meta gives no idempotency header, thus `Threads#post!`
# keeps the id of the media container in Redis below `key`. A retry then publishes the container
# that it made already, in place of a second one.
#
# ⚠️ There is one job for each network, and not one job for all of them. Thus a failure at one
# service retries that service alone, and a network that already posted is never sent again.
class ThreadsPostJob < ApplicationJob
  # @param key [String] The idempotency key, which is the same value for each attempt.
  # @param url [String] The link to share. Threads attaches it as a link_attachment.
  # @param text [String] The body of the post.
  def perform(key, url, text)
    posted = Threads.new.post!(text: text, url: url, idempotency_key: key)
    Rails.logger.info("ThreadsPostJob: posted #{posted}")
  end
end

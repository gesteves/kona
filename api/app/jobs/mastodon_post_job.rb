# Posts one draft from the Social media page to Mastodon.
#
# ⚠️ You can do this job more than one time. `key` goes in the `Idempotency-Key` header, and the
# instance then answers with the status that it made already. ⚠️ That window is not for ever, thus
# a retry a long time later can still make a second post.
#
# ⚠️ There is one job for each network, and not one job for all of them. Thus a failure at one
# service retries that service alone, and a network that already posted is never sent again.
class MastodonPostJob < ApplicationJob
  # @param key [String] The idempotency key, which is the same value for each attempt.
  # @param url [String] The link to share. Mastodon renders it in the text.
  # @param text [String] The body of the post.
  def perform(key, url, text)
    posted = Mastodon.new.post!(text: text, url: url, idempotency_key: key)
    Rails.logger.info("MastodonPostJob: posted at #{posted}")
  end
end

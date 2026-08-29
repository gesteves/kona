# Posts one draft from the Social media page to Bluesky.
#
# ⚠️ You can do this job more than one time. The caller makes `key` before it adds the job, and
# `Bluesky#post!` writes with `putRecord` at that key. Thus a retry replaces the same record and
# never adds a second post. `createRecord` would make a new key at each attempt.
#
# ⚠️ There is one job for each network, and not one job for all of them. Thus a failure at one
# service retries that service alone, and a network that already posted is never sent again.
class BlueskyPostJob < ApplicationJob
  # @param key [String] The record key of the post, from Bluesky.new_tid.
  # @param url [String] The link to share.
  # @param text [String] The body of the post.
  def perform(key, url, text)
    # ⚠️ The card is for Bluesky only. Mastodon and Threads each make their own preview from the
    # same og: tags, thus neither of those jobs reads them.
    posted = Bluesky.new.post!(rkey: key, text: text, card: OpenGraph.new.fetch(url))
    Rails.logger.info("BlueskyPostJob: posted at #{posted}")
  end
end

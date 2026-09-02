# Posts one post of a draft from the Social media page to Bluesky, then adds the job of the next
# one.
#
# ⚠️ **There is one job for each POST, and not one job for the whole thread.** Thus a failure runs
# **one** post again, and never a post that already went out. A job that posted the whole chain
# would, on a retry, go back to the top of it.
#
# ⚠️ You can do each attempt more than one time. The caller makes `key` for each post before it adds
# the first job, and `Bluesky#post!` writes with `putRecord` at that key. Thus a retry replaces the
# same record. The reply reference travels in the arguments, thus it is the same at each attempt.
class BlueskyPostJob < ApplicationJob
  # @param posts [Array<Hash>] `[{ "key" =>, "text" =>, "link" => }, …]`, the whole thread.
  # @param index [Integer] Which post of that list this job writes.
  # @param reply [Hash, nil] `{ "root" =>, "parent" => }` of the post above, or nil for the first.
  def perform(posts, index = 0, reply = nil)
    post = posts[index]
    return if post.blank?

    # ⚠️ It logs BEFORE the request. A failure raises, thus without this line the report
    # names no post of the thread and a thread of five gives five reports that read alike.
    Rails.logger.info("BlueskyPostJob: posting #{index + 1}/#{posts.length}")

    # ⚠️ The card is for Bluesky only, and it reads the page. Mastodon and Threads each make their
    # own preview from the same og: tags. A post with no link reads nothing.
    card = OpenGraph.new.fetch(post["link"]) if post["link"].present?

    # ⚠️ **A page with no og: tags gets NO embed, and its link goes in the words**, as it does at
    # Mastodon. An embed from such a page is an empty box with a host name in it.
    # `Admin::SocialController` reads the same `embeddable?` rule, thus the count on the page holds
    # this link as well.
    embed = card if card&.embeddable?
    text = Bluesky.compose(text: post["text"], url: (post["link"] if card && embed.nil?))

    # ⚠️ The page measured at the submit had a card, and a scheduled post can run days later. A
    # page that lost its og: tags puts the link in the words, and the words can then pass 300. The
    # post goes out with no link, which is the degraded answer, and not a retry of one day.
    if embed.nil? && text != post["text"] && !Bluesky.valid_post_length?(text)
      Rails.logger.warn("BlueskyPostJob: post #{index + 1}/#{posts.length} drops its link, which no longer fits")
      text = post["text"]
    end

    written = Bluesky.new.post!(rkey: post["key"], text: text, card: embed, reply: reply)
    Rails.logger.info("BlueskyPostJob: posted #{index + 1}/#{posts.length} at #{written['url']}")

    self.class.perform_async(posts, index + 1, next_reply(reply, written)) if posts[index + 1]
  end

  private

  # ⚠️ The **root** of a thread is the first post, and the **parent** is the one just above. This
  # carries the root through the chain and never makes it again.
  # @return [Hash] The reply of the next post.
  def next_reply(reply, written)
    { "root" => reply&.dig("root") || written.slice("uri", "cid"),
      "parent" => written.slice("uri", "cid") }
  end
end

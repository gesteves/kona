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
    written = Bluesky.new.post!(rkey: post["key"], text: post["text"], card: card, reply: reply)
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

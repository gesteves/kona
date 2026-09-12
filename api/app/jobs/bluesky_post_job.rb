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
  # How long the lock of one post stays. ⚠️ It is longer than the 24-hour retry window of
  # ApplicationJob, thus a late retry cannot add the same post a second time.
  ENQUEUE_LOCK_TTL = 36.hours.to_i

  # The prefix of each lock key. ⚠️ `spec/support/at_proto_session.rb` removes these keys before
  # each example, thus a lock cannot go from one example to the next one.
  ENQUEUE_LOCK_PREFIX = "bluesky:thread:".freeze

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

    enqueue_next(posts, index + 1, next_reply(reply, written))
  end

  private

  # ⚠️ The **root** of a thread is the first post, and the **parent** is the one just above. This
  # carries the root through the chain and never makes it again.
  # @return [Hash] The reply of the next post.
  # Adds the job of the next post, one time only.
  #
  # ⚠️ This enqueue is INSIDE the job of the post above it. When the process dies after the enqueue
  # and before Sidekiq acknowledges the job, the retry does that post again — which is safe, the
  # rkey is the same — AND it adds the next job a second time. The tail of the thread then goes out
  # two times: two sessions, two blob uploads, and two jobs for each post below this one. The
  # record key of the next post is the thing that is the same across both, thus it is the lock.
  # @param posts [Array<Hash>]
  # @param index [Integer] The post to add.
  # @param reply [Hash] The reference of its parent.
  # @return [void]
  def enqueue_next(posts, index, reply)
    post = posts[index]
    return if post.blank?

    # ⚠️ The record key is the lock, thus a post with none cannot take one. A fallback to the index
    # would make one key — `…:1` — that EVERY thread shares, and the second post of each other
    # thread would then go away for 36 hours. `Admin::SocialController` always makes the keys, and
    # `Bluesky#post!` cannot write without one.
    key = post["key"].presence
    return if key.blank?
    return unless $redis.set("#{ENQUEUE_LOCK_PREFIX}#{key}", "1", nx: true, ex: ENQUEUE_LOCK_TTL)

    begin
      self.class.perform_async(posts, index, reply)
    rescue StandardError
      # ⚠️ Give the lock back. The lock is above the enqueue, thus a Redis failure here would leave
      # it for 36 hours: the retry of this job posts again at the same rkey, finds the lock, and
      # SUCCEEDS with the rest of the thread never sent and nothing to report it.
      $redis.del("#{ENQUEUE_LOCK_PREFIX}#{key}")
      raise
    end
  end

  def next_reply(reply, written)
    { "root" => reply&.dig("root") || written.slice("uri", "cid"),
      "parent" => written.slice("uri", "cid") }
  end
end

# Posts one draft from the Share page to each social network that the owner selected.
#
# ⚠️ You can do this job more than one time. The caller makes `rkey` **before** it adds the job, and
# `Bluesky#post!` writes with `putRecord`. Thus a retry replaces the same record and never adds a
# second post to the feed. Without that key, the 24-hour retry of the parent class would post the
# same words again at each attempt.
#
# ⚠️ Only Bluesky posts today. Mastodon and Threads have their tokens and their write scopes, and no
# code sends to them. The job names each one that it skips in the log.
class SharePostJob < ApplicationJob
  # The networks that this job can send to. A key outside this list is a skip and not an error.
  SUPPORTED = %w[bluesky].freeze

  # @param rkey [String] The record key of the post, from Bluesky.new_tid.
  # @param url [String] The link to share. It can be an article of this site or another site.
  # @param text [String] The body of the post.
  # @param networks [Array<String>] The keys that the owner selected.
  def perform(rkey, url, text, networks)
    selected = Array(networks) & SUPPORTED
    skipped = Array(networks) - SUPPORTED
    Rails.logger.info("SharePostJob: #{skipped.join(', ')} not wired up yet; skipped") if skipped.any?
    return if selected.empty?

    # ⚠️ The card comes from the page itself, and not from Contentful. The link can be a Short,
    # which has no cover image, or a page on another site. `OpenGraph#fetch` never raises: with no
    # tags the card holds the URL alone, and Bluesky renders that.
    card = OpenGraph.new.fetch(url)

    posted = Bluesky.new.post!(rkey: rkey, text: text, card: card)
    Rails.logger.info("SharePostJob: posted to Bluesky at #{posted}")
  end
end

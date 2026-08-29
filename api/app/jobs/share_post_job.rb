# Posts one draft from the Share page to each social network that the owner selected.
#
# ⚠️ You can do this job more than one time, and each network has its own reason that this is safe:
#   - **Bluesky** — the caller makes `rkey` before it adds the job, and `Bluesky#post!` writes with
#     `putRecord`. Thus a retry replaces the same record.
#   - **Mastodon** — the same `rkey` goes in the `Idempotency-Key` header, and the instance then
#     answers with the status that it already made. ⚠️ That window is not for ever, thus a retry a
#     long time later can still make a second post.
#
# ⚠️ Threads does not post yet. It has its token and its write scope, and no code sends to it. The
# job names each network that it skips in the log, and the notice of the page says so as well.
class SharePostJob < ApplicationJob
  # The networks that this job can send to. A key outside this list is a skip and not an error.
  SUPPORTED = %w[bluesky mastodon].freeze

  # @param rkey [String] The record key of the post, from Bluesky.new_tid. It is also the
  #   idempotency key of Mastodon.
  # @param url [String] The link to share. It can be an article of this site or another site.
  # @param text [String] The body of the post.
  # @param networks [Array<String>] The keys that the owner selected.
  def perform(rkey, url, text, networks)
    selected = Array(networks) & SUPPORTED
    skipped = Array(networks) - SUPPORTED
    Rails.logger.info("SharePostJob: #{skipped.join(', ')} not wired up yet; skipped") if skipped.any?
    return if selected.empty?

    failures = post_to_each(selected, rkey: rkey, url: url, text: text)

    # ⚠️ It raises after it tried each network, and not at the first failure. Thus one service that
    # is away does not stop the other one, and the retry then sends to both again. The idempotency
    # of each network above is what makes that second send safe.
    raise "SharePostJob: #{failures.join('; ')}" if failures.any?
  end

  private

  # @return [Array<String>] One line for each network that failed.
  def post_to_each(selected, rkey:, url:, text:)
    selected.filter_map do |key|
      posted = post_to(key, rkey: rkey, url: url, text: text)
      Rails.logger.info("SharePostJob: posted to #{key} at #{posted}")
      nil
    rescue StandardError => e
      "#{key}: #{e.message}"
    end
  end

  # ⚠️ This is a `case` and not a `send` of the key. That key comes from a form, and the list above
  # is the only thing that keeps it safe. One place to read is better than two.
  # @return [String] The public URL of the post.
  def post_to(key, rkey:, url:, text:)
    case key
    when "bluesky"
      # ⚠️ The card is for Bluesky only, thus this runs only when Bluesky is selected. Mastodon
      # renders the link inline and makes its own preview from the same og: tags.
      Bluesky.new.post!(rkey: rkey, text: text, card: OpenGraph.new.fetch(url))
    when "mastodon"
      Mastodon.new.post!(text: text, url: url, idempotency_key: rkey)
    end
  end
end

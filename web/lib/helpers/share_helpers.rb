require 'erb'

module ShareHelpers
  # Each share network's endpoint and query params, in the order they appear in the URL.
  # A Symbol param value carries that part of the share (:title or :url); a String value is
  # a format template combining both, encoded as one blob. The shared article URL is clean —
  # no attribution query params.
  SHARE_NETWORKS = {
    'Email'    => { base: 'mailto:?',                                    params: { subject: :title, body: :url } },
    'SMS'      => { base: 'sms:?&',                                      params: { body: '%{title} %{url}' } },
    'Facebook' => { base: 'https://www.facebook.com/sharer/sharer.php?', params: { u: :url } },
    'Reddit'   => { base: 'https://reddit.com/submit?',                  params: { title: :title, url: :url } },
    'Bluesky'  => { base: 'https://bsky.app/intent/compose?',            params: { text: "%{title}\n\n%{url}" } },
    'Threads'  => { base: 'https://www.threads.com/intent/post?',        params: { text: :title, url: :url } },
    'Mastodon' => { base: 'https://share.joinmastodon.org/?',            params: { text: "%{title}\n\n%{url}" } }
  }.freeze

  # Builds the share URL for an article on a network.
  # @param network [String] A SHARE_NETWORKS key.
  # @param article [Article] The article to share.
  # @return [String] The share URL.
  def share_url(network, article)
    config = SHARE_NETWORKS.fetch(network)
    parts = { title: sanitize(article.title), url: full_url(article.path) }
    query = config[:params].map do |param, value|
      part = value.is_a?(Symbol) ? parts.fetch(value) : format(value, parts)
      "#{param}=#{ERB::Util.url_encode(part)}"
    end
    "#{config[:base]}#{query.join('&')}"
  end

  # The share buttons rendered by partials/_share.html.erb, in display order. Defaults the
  # loop fills in: `via` falls back to the network name, `action` to "trackShare", and
  # `new_tab` to true.
  # @return [Array<Hash>]
  def share_buttons
    [
      { label: 'Share by email',        network: 'Email',   icon: %w[solid envelope], new_tab: false },
      { label: 'Share by text message', network: 'SMS',     via: 'Text', icon: %w[solid comment], new_tab: false },
      { label: 'Share on Bluesky',      network: 'Bluesky', icon: %w[brands bluesky] },
      { label: 'Share on Facebook',     network: 'Facebook', icon: %w[brands facebook], action: 'openPopup' },
      { label: 'Share on Mastodon',     network: 'Mastodon', icon: %w[brands mastodon] },
      { label: 'Share on Reddit',       network: 'Reddit',  icon: %w[brands reddit] },
      { label: 'Share on Threads',      network: 'Threads', icon: %w[brands threads] }
    ]
  end

  # @param article [Article] The article to share.
  # @return [String] The share section's heading, naming the entry's kind.
  def share_heading(article)
    # Matched by concept id, not display name, like every other taxonomy check in the app
    # (article_helpers.rb's race_report?). A rename in Contentful would silently drop this to
    # the generic "Share this post".
    tag_ids = Array(article&.contentful_metadata&.tags).map(&:id)
    type = if tag_ids.include?('race-reports')
             'race report'
           elsif tag_ids.include?('reviews')
             'review'
           else
             entry_type(article)&.downcase || 'post'
           end
    "Share this #{type}"
  end
end

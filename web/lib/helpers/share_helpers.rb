require "erb"

module ShareHelpers
  # The endpoint and the query parameters of each share network, in the order that they have in the
  # URL. A parameter value that is a Symbol gives that part of the share: :title or :url. A value
  # that is a String is a template that joins the two into one encoded value. The article URL that
  # the app shares is clean: it has no attribution query parameters.
  SHARE_NETWORKS = {
    "Email"    => { base: "mailto:?",                                    params: { subject: :title, body: :url } },
    "SMS"      => { base: "sms:?&",                                      params: { body: "%{title} %{url}" } },
    "Facebook" => { base: "https://www.facebook.com/sharer/sharer.php?", params: { u: :url } },
    "Reddit"   => { base: "https://reddit.com/submit?",                  params: { title: :title, url: :url } },
    "Bluesky"  => { base: "https://bsky.app/intent/compose?",            params: { text: "%{title}\n\n%{url}" } },
    "Threads"  => { base: "https://www.threads.com/intent/post?",        params: { text: :title, url: :url } },
    "Mastodon" => { base: "https://share.joinmastodon.org/?",            params: { text: "%{title}\n\n%{url}" } }
  }.freeze

  # Makes the share URL of an article for one network.
  # @param network [String] A key of SHARE_NETWORKS.
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

  # The share buttons that partials/_share.html.erb renders, in the order that they appear. The loop
  # adds these default values: `via` becomes the name of the network, `action` becomes "trackShare",
  # and `new_tab` becomes true.
  # @return [Array<Hash>]
  def share_buttons
    [
      { label: "Share by email",        network: "Email",   icon: %w[solid envelope], new_tab: false },
      { label: "Share by text message", network: "SMS",     via: "Text", icon: %w[solid comment], new_tab: false },
      { label: "Share on Bluesky",      network: "Bluesky", icon: %w[brands bluesky] },
      { label: "Share on Facebook",     network: "Facebook", icon: %w[brands facebook], action: "openPopup" },
      { label: "Share on Mastodon",     network: "Mastodon", icon: %w[brands mastodon] },
      { label: "Share on Reddit",       network: "Reddit",  icon: %w[brands reddit] },
      { label: "Share on Threads",      network: "Threads", icon: %w[brands threads] }
    ]
  end

  # @param article [Article] The article to share.
  # @return [String] The heading of the share section, with the type of the entry in it.
  def share_heading(article)
    # The match uses the concept id and not the name on the screen, as each other taxonomy check in
    # the app does (refer to race_report? in article_helpers.rb). A new name in Contentful would
    # change this to the general "Share this post", with no message.
    tag_ids = Array(article&.contentful_metadata&.tags).map(&:id)
    type = if tag_ids.include?("race-reports")
             "race report"
    elsif tag_ids.include?("reviews")
             "review"
    else
             entry_type(article)&.downcase || "post"
    end
    "Share this #{type}"
  end
end

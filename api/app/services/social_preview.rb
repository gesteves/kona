require "uri"

# The draft of the Social media page as each connected network will receive it, for the preview
# dialog of the page, and the website card of one link.
#
# ⚠️ **It reads the same `SocialDraft` as the action that posts.** Thus the preview cannot show a
# text that the post does not send, and a change to the substitution reaches both. It writes
# nothing and it adds no job.
#
# The caller gives each path as a callable, and this class does not make one. Thus it uses no
# route helper.
class SocialPreview
  # The network whose preview shows the LINK below the words.
  #
  # ⚠️ Bluesky is absent because the panel draws its card, and Mastodon is absent because
  # `Mastodon.compose` puts the link in the text, thus it is already a segment there. Threads
  # makes an attachment that Meta renders and this app cannot draw, thus the panel shows the
  # address itself.
  LINK_SHOWN = "threads".freeze

  # @param draft [SocialDraft]
  # @param photo_path [#call] Gives the path of a stored photo from its id.
  # @param image_path [#call] Gives the path of the proxy of a card picture from the URL of the
  #   page.
  def initialize(draft:, photo_path:, image_path:)
    @draft = draft
    @photo_path = photo_path
    @image_path = image_path
  end

  # Each network that can take the draft, with its posts.
  #
  # ⚠️ A draft with a Markdown link shows BLUESKY alone, and a draft with photos shows only the
  # networks that take that many. To render another network would show a text that this app
  # refuses to post. The composer turns the checkboxes off by the same rules, thus the page and
  # the dialog agree.
  #
  # ⚠️ It groups by NETWORK and not by post, thus the panel reads as the thread reads: each
  # network in turn, and its posts in the order that they go out.
  # @return [Array<Hash>] `[{ key:, name:, posts: [...] }, …]`
  def networks
    shown = @draft.networks.select(&:connected?)
    shown = shown.select(&:markdown?) if @draft.markdown?
    shown = shown.select { |network| @draft.takes_photos?(network.key) }

    shown.map do |network|
      { key: network.key, name: network.name,
        posts: @draft.posts.map { |post| post_json(network.key, post) } }
    end
  end

  # One website card, as JSON.
  #
  # ⚠️ **The card below a link field and the card in the preview panel read this same method**,
  # thus the two cannot describe one page differently.
  #
  # ⚠️ It is memoized by URL: a thread that names one link in two posts reads that page one time.
  # `OpenGraph#fetch` also caches for 15 minutes, thus a preview warms the cache that the post job
  # reads a moment later.
  # @param url [String]
  # @return [Hash]
  def card_json(url)
    @card_json ||= {}
    @card_json[url] ||= begin
      card = @draft.card_for(url)
      {
        url: card.url,
        title: card.title,
        description: card.description,
        host: host_of(card.url),
        # ⚠️ The path of our own proxy, and never the og:image itself. Refer to
        # `Admin::SocialController#preview_image`.
        image_path: (@image_path.call(url) if card.image_url.present?),
        standard_site: card.document_uri.present?,
        # ⚠️ False means that Bluesky renders NO card and the link goes in the words. The browser
        # reads this to add the link to its count.
        embeddable: card.embeddable?
      }
    end
  end

  private

  # One post of one network.
  # @param network [String] A network key.
  # @param post [Hash]
  # @return [Hash]
  def post_json(network, post)
    limit = @draft.limit_of(network)
    length = @draft.length_for(network, post)
    text, links = @draft.composed(network, post)

    { text: text, segments: segments(text, links), length: length, limit: limit,
      over: length > limit, topic: topic_of(network),
      link: link_of(network, post), card: card_of(network, post),
      photos: photos_of(network, post) }
  end

  # The text in pieces, so that the dialog can render each link as a link.
  #
  # ⚠️ **A `url` is always http or https**, because `MarkdownLinks::URL_PATTERN` and
  # `Bluesky::URL_PATTERN` both start with that scheme. Thus the browser can write one into an
  # `href` with no check of its own, and no draft can make a `javascript:` link in the admin.
  # @param text [String]
  # @param links [Array<MarkdownLinks::Link>] In order, and with no overlap.
  # @return [Array<Hash>] `[{ text: }, { text:, url: }, …]`, in order and with no gap.
  def segments(text, links)
    pieces = []
    last = 0

    links.each do |link|
      pieces << { text: text[last...link.start] } if link.start > last
      pieces << { text: text[link.start...link.finish], url: link.url }
      last = link.finish
    end

    pieces << { text: text[last..] } if last < text.length
    pieces
  end

  # ⚠️ It is the topic ITSELF and not a sentence about it: the panel renders it as a badge above
  # the words, which is where the Threads app shows it. Each post carries it, exactly as
  # `SocialDraft#payload` sends it.
  # @return [String, nil]
  def topic_of(network)
    return nil unless network == SocialPresenter::TOPIC_NETWORK && @draft.topic.present?

    @draft.topic
  end

  # ⚠️ It is NOT part of the text and it uses none of the characters of that network: Threads
  # makes an attachment of it. The panel shows it below the words, because a post with a link
  # that nothing shows reads as a post with no link.
  # @return [String, nil]
  def link_of(network, post)
    return nil unless network == LINK_SHOWN && post[:link].present?

    post[:link]
  end

  # The website card that Bluesky will render for the link of a post.
  #
  # ⚠️ **Bluesky alone**, because this app BUILDS that card: `Bluesky#build_card` makes an
  # `app.bsky.embed.external` from these same og: tags. Threads gets a `link_attachment` and Meta
  # renders a preview of its own, thus this app has nothing to show for it.
  # @return [Hash, nil]
  def card_of(network, post)
    return nil unless network == "bluesky" && post[:link].present?
    return nil unless OpenGraph.http_url?(post[:link])
    # ⚠️ A page with no og: tags gets no card at all, thus the panel draws none. Its link is in
    # the words of the post, which the row above already shows.
    return nil unless @draft.card_for(post[:link]).embeddable?

    card_json(post[:link])
  end

  # The photos of a post, for the row of each network that takes them.
  # @return [Array<Hash>, nil] `[{ path:, alt: }, …]`, or nil for each other network.
  def photos_of(network, post)
    return nil unless SocialPresenter::PHOTO_LIMITS.key?(network) && post[:photos].any?

    post[:photos].map { |photo| { path: @photo_path.call(photo[:id]), alt: photo[:alt] } }
  end

  # @param url [String, nil]
  # @return [String, nil] The host of a URL, for the line below the title of the card.
  def host_of(url)
    URI.parse(url.to_s).host
  rescue URI::InvalidURIError
    nil
  end
end

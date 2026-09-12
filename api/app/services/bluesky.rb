# Posts to Bluesky, as the account that Connected apps holds.
#
# ⚠️ This is not `StandardSite`. That class writes `site.standard.*` records, which are a mirror of
# the blog, and this one writes an `app.bsky.feed.post`, which is a post that a reader sees in a
# feed. The two share the account, the session, and the blob upload, through `AtProto`.
#
# @see https://atproto.com/blog/create-post
class Bluesky < ApplicationService
  include AtProto

  COLLECTION = "app.bsky.feed.post".freeze

  # The limit of a post, in grapheme clusters. ⚠️ `SocialPresenter::BODY_LIMIT` is the same number on
  # the admin page, and `spec/services/bluesky_spec.rb` pins the two together.
  MAX_GRAPHEMES = 300

  # The limit of a post in BYTES. ⚠️ `app.bsky.feed.post#text` has two limits, and this is the
  # second one. 300 family emoji is 300 graphemes and approximately 7,500 bytes: the PDS refuses
  # that record, thus a check of the graphemes alone permits a post that can never go out, and
  # `BlueskyPostJob` then tries it again for 24 hours.
  MAX_BYTES = 3_000

  # The limits of one `app.bsky.richtext.facet#tag`. ⚠️ A tag past one of them makes the full
  # record invalid, thus a long hashtag takes the post away with it.
  MAX_TAG_GRAPHEMES = 64
  MAX_TAG_BYTES = 640

  # The largest blob that a PDS takes for a card thumbnail. A record with a larger one fails at
  # `putRecord` and not at the upload, thus the reason arrives late and reads as "blob too big".
  MAX_BLOB_BYTES = 976_560
  # The most bytes of an og:image that this class downloads. ⚠️ The picture belongs to a page that
  # the owner linked to, and the worker is a 512MB VM at concurrency 5. A picture past this limit
  # loses the thumbnail and never the post.
  MAX_CARD_IMAGE_BYTES = 10 * 1024 * 1024
  # The width to shrink an oversized thumbnail to. Bluesky renders a card at approximately this
  # width, thus a larger picture is only bandwidth.
  CARD_IMAGE_WIDTH = 1200
  # The JPEG quality of that shrink.
  CARD_IMAGE_QUALITY = 80

  # The steps of the shrink, in order.
  #
  # ⚠️ One shrink is not always enough: a picture of 1200px at Q80 can stay above the limit, and the
  # card then lost its thumbnail. This walks down the steps and takes the first result that fits.
  # It makes the quality lower first, because a person sees a smaller picture before they see a
  # lower quality.
  CARD_IMAGE_STEPS = [
    { width: CARD_IMAGE_WIDTH, quality: CARD_IMAGE_QUALITY },
    { width: CARD_IMAGE_WIDTH, quality: 65 },
    { width: CARD_IMAGE_WIDTH, quality: 50 },
    { width: 900, quality: 50 },
    { width: 700, quality: 45 }
  ].freeze

  # The limits of the text fields of a card.
  CARD_TITLE_MAX = 300
  CARD_DESCRIPTION_MAX = 1000

  # The language of each post. This blog is in English.
  LANGS = [ "en-US" ].freeze

  # An @handle, from the sample in the AT Protocol documentation.
  MENTION_PATTERN = /(?:^|[$|\W])(@(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)/
  # A bare URL. It does not take a trailing period or bracket, which is nearly always punctuation
  # of the sentence and not part of the address.
  URL_PATTERN = %r{(?:^|[$|\W])(https?://[a-zA-Z0-9\-._~:/?\#\[\]@!$&'()*+,;%=]*[a-zA-Z0-9\-_~/\#@$&*+=])}
  # The zero-width and formatting characters that a tag cannot hold, from the tag rule of the
  # Bluesky client.
  TAG_EXCLUDED = "\u00AD\u2060\u200A\u200B\u200C\u200D\u20E2".freeze

  # A #hashtag, from the rule of the Bluesky client, thus a facet covers the same characters that a
  # reader sees tagged.
  #
  # ⚠️ It does not use `\w`. Ruby reads `\w` as ASCII, thus "#café" gave the tag "caf" and a facet
  # over one part of a word. It needs one character that is not a digit and not punctuation, which
  # is what keeps "#1" a number, and it starts at a space or at the start of the text, as the
  # client does.
  TAG_PATTERN = /(?:^|\s)([#＃](?!\uFE0F)[^\s#{TAG_EXCLUDED}]*[^\d\s\p{P}#{TAG_EXCLUDED}]+[^\s#{TAG_EXCLUDED}]*)/

  TAG_PREFIX = /\A[#＃]/

  # The client removes the punctuation at the end of a tag, thus "#trail." tags "trail".
  TRAILING_PUNCTUATION = /\p{P}+\z/

  # The number of grapheme clusters in a post.
  #
  # ⚠️ Bluesky counts graphemes, and `String#length` counts UTF-16 code units. One emoji is 1 there
  # and 2 or more here. `social_post_controller.js` counts the same way in the browser, with
  # `Intl.Segmenter`.
  #
  # ⚠️ **It counts the text that the RECORD will hold, thus it renders the Markdown first.** The
  # address of a link is in a facet and not in the text, thus `[my post](https://example.com/a)` is
  # 7 characters and not 30. A count of the words that the owner typed would refuse a draft that
  # Bluesky takes.
  # @param text [String, nil]
  # @return [Integer]
  def self.post_length(text)
    SocialText.graphemes(MarkdownLinks.render(text))
  end

  # ⚠️ It reads the GRAPHEMES and the BYTES. The lexicon has both limits, and emoji-heavy words
  # pass the first one and fail the second one.
  # @param text [String, nil]
  # @return [Boolean] True when the text fits in one post and is not empty.
  def self.valid_post_length?(text)
    plain = MarkdownLinks.render(text)
    length = SocialText.graphemes(plain)
    length.positive? && length <= MAX_GRAPHEMES && plain.bytesize <= MAX_BYTES
  end

  # Each link of a post, in order, as CHARACTER offsets into the plain text.
  #
  # ⚠️ **This is the ONE list.** `#build_facets` makes a facet from each entry, and the preview of
  # the Social media page renders each entry as an `<a>`. Thus the dialog cannot show a link that
  # the post does not make, and it cannot miss one that it does.
  #
  # ⚠️ A bare URL inside the words of a Markdown link is not a second link. `[https://a](https://b)`
  # would otherwise get two facets over one range, and a client renders that as a broken link.
  # @param text [String, nil] The PLAIN text, which `MarkdownLinks.render` makes.
  # @param markdown [Array<MarkdownLinks::Link>] The links that the Markdown made, from the same
  #   parse that made the text.
  # @return [Array<MarkdownLinks::Link>]
  def self.link_ranges(text, markdown = [])
    text = text.to_s
    taken = markdown.map { |link| link.start...link.finish }
    bare = []

    SocialText.url_ranges(text).each do |range|
      next if taken.any? { |other| other.cover?(range.begin) }

      bare << MarkdownLinks::Link.new(start: range.begin, finish: range.end, url: text[range])
    end

    (markdown + bare).sort_by(&:start)
  end

  # The text that one post will hold.
  #
  # ⚠️ **The link is in the WORDS only when the page gives no card**, that is, when
  # `OpenGraph::Card#embeddable?` is false. An embed keeps the URL out of the 300 characters, thus
  # a page with og: tags never comes here with a `url`. `Mastodon.compose` is the same method, and
  # a Mastodon status always holds its link.
  # @param text [String, nil] The body of the post.
  # @param url [String, nil] The link to add below the body.
  # @return [String]
  def self.compose(text:, url: nil)
    SocialText.compose(text: text, url: url)
  end

  # Makes the public URL of a post from its record key.
  # @param handle [String] The handle of the account.
  # @param rkey [String] The record key.
  # @return [String]
  def self.post_url(handle, rkey)
    "https://bsky.app/profile/#{handle}/post/#{rkey}"
  end

  # @param credentials [BlueskyCredentials::Credentials] The pair that opens the session.
  def initialize(credentials: BlueskyCredentials.fetch)
    @handle = credentials.handle
    @app_password = credentials.app_password
  end

  # @return [Boolean] True when both credentials are available.
  def valid_credentials? = @handle.present? && @app_password.present?

  # @return [String, nil] The handle of the connected account.
  attr_reader :handle

  # Publishes one post.
  #
  # ⚠️ The caller gives the `rkey`, and this method uses `putRecord` and not `createRecord`. Thus a
  # second attempt of the same job replaces the same record and does not add a second post.
  # `createRecord` makes a new key each time, and each retry there is a new post in the feed.
  # Use `Bluesky.new_tid` to make that key **before** you add the job.
  #
  # @param rkey [String] The record key, from `Bluesky.new_tid`.
  # @param text [String] The body of the post, as plain text.
  # @param card [OpenGraph::Card, nil] The card of the link, from `OpenGraph#fetch`. Nil gives a
  #   post with no card at all. ⚠️ **Give a card that is `embeddable?` only.** A card with no
  #   title, no description, and no picture renders as an empty box, thus the caller puts that link
  #   in `text` with `Bluesky.compose` and sends no card.
  # @param reply [Hash, nil] `{ "root" =>, "parent" => }`, each a reference from an earlier call.
  #   ⚠️ The **root** is the first post of the thread, and the **parent** is the one just above.
  #   The caller carries the root through the chain and never makes it again.
  # @return [Hash] `{ "uri" =>, "cid" =>, "url" => }`. The next post of a thread names this one with
  #   the `uri` and the `cid`.
  # @raise [RuntimeError] When the credentials, the length, the session, or the write fails. It
  #   raises on purpose: `BlueskyPostJob` then does the work again.
  def post!(rkey:, text:, card: nil, reply: nil)
    raise ApplicationJob::PermanentError, "Bluesky is not connected" unless valid_credentials?
    raise ApplicationJob::PermanentError, "The post is empty or longer than #{MAX_GRAPHEMES} characters" unless self.class.valid_post_length?(text)
    raise "Could not open a Bluesky session" unless open_session(handle: @handle, app_password: @app_password)

    # ⚠️ **The Markdown is rendered HERE, and not in the action.** The record holds the plain words
    # and the address of each link is in a facet, thus the two must be made from one parse. The
    # action sends the words that the owner wrote, and each retry of the job renders them again.
    post = MarkdownLinks.parse(text)

    record = {
      "$type" => COLLECTION,
      "text" => post.text,
      "langs" => LANGS,
      # ⚠️ MILLISECONDS. `iso8601` with no argument gives whole seconds, and two posts of one thread
      # go out inside the same second: both then carry the same createdAt. The AppView sorts an
      # author feed by that value, and the root of the thread went missing from the Posts tab while
      # its reply stayed. Each other client writes milliseconds, and `StandardSite` does as well.
      # ⚠️ The time comes from the record key, thus each attempt writes the same bytes and the CID
      # does not change. A new CID would make the `parent` of a published reply point at a version
      # that is gone.
      "createdAt" => (self.class.tid_time(rkey) || Time.now).utc.iso8601(3)
    }
    facets = build_facets(post.text, links: post.links)
    record["facets"] = facets if facets.any?
    embed = build_card(card)
    record["embed"] = embed if embed.present?
    record["reply"] = reply if reply.present?

    # ⚠️ It does not send `validate: false`. The PDS knows the app.bsky.* lexicons, thus its own
    # check finds a record with an error before the post reaches a feed.
    written = put_record(COLLECTION, rkey, record, validate: nil)
    raise "Bluesky refused the post" if written.blank?

    written.merge("url" => self.class.post_url(@handle, rkey))
  end

  # Gets the picture of a website card, ready to go up as a blob.
  #
  # ⚠️ **This is public because the Social media preview proxies it.** The admin cannot show an `og:image`
  # from another host directly: the CSP of the admin has `img-src :self`. Thus the preview asks this
  # app for the picture, and it then shows **the exact bytes that this class uploads** and not the
  # original file.
  #
  # Each step fails soft, on purpose: a picture past `MAX_CARD_IMAGE_BYTES`, a body that is not an
  # image, and a decode that fails each give nil. A card with no picture still renders.
  # @param url [String, nil] The og:image.
  # @return [Hash, nil] `{ body:, content_type: }`, or nil after any failure.
  def card_image(url)
    return if url.blank?

    picture = download(url, max_bytes: MAX_CARD_IMAGE_BYTES,
                            headers: { "User-Agent" => OpenGraph::USER_AGENT },
                            open_timeout: OpenGraph::OPEN_TIMEOUT, read_timeout: OpenGraph::READ_TIMEOUT,
                            limit: 5)
    return if picture.nil?

    bytes = picture[:body]
    mime = picture[:content_type].to_s.split(";").first.to_s.strip

    # ⚠️ A host with no content type, or a 200 that is an HTML error page, must not go up as a
    # picture. The shrink decodes the bytes with libvips, thus it is also the check that they are
    # an image. It runs for an oversized picture for the same reason as before: a blob past the
    # limit fails at putRecord.
    bytes, mime = shrink(bytes) if !mime.start_with?("image/") || bytes.bytesize > MAX_BLOB_BYTES
    return if bytes.blank? || bytes.bytesize > MAX_BLOB_BYTES

    { body: bytes, content_type: mime }
  rescue StandardError => e
    report_upstream_error(e, context: "bluesky card image", url: url)
    nil
  end

  # Asks the PDS if a handle exists.
  #
  # ⚠️ **It answers true ONLY for a definite refusal.** A PDS that is away, slow, or broken gives
  # false and the draft goes out. An outage there must never stop a post to Mastodon and Threads.
  #
  # ⚠️ `#resolve_handle` cannot answer this question: it gives nil for "the PDS does not know that
  # handle" AND for "the PDS did not answer". Thus the Social media action needs this method, and
  # fail-open is the branch that falls through and not a rescue that a person can delete.
  # @param handle [String, nil] A handle, with no "@".
  # @return [Boolean]
  def handle_missing?(handle)
    return false if handle.blank?

    response = resolve_handle_response(handle)
    # A PDS answers 400 InvalidRequest for a handle that it cannot resolve.
    response.code == 400
  rescue StandardError
    false
  end

  private

  # @return [String] The name of this client in each log line of AtProto.
  def at_proto_label = "bluesky"

  # Makes the website card of the link.
  #
  # ⚠️ The link of a post is this card, and it is **not** in the text. Thus the URL does not use
  # part of the 300 characters. ⚠️ The caller gives an `embeddable?` card only: a page with no
  # tags makes an empty box, and the link goes in the words instead. A card with no thumbnail still
  # renders, thus a failure of the image
  # loses the picture only and never the post.
  # @param card [OpenGraph::Card, nil]
  # @return [Hash, nil] An app.bsky.embed.external, or nil with no card.
  def build_card(card)
    return if card.blank? || card.url.blank?

    external = { "uri" => card.url }
    external["title"] = truncate_graphemes(card.title.to_s, CARD_TITLE_MAX).to_s
    external["description"] = truncate_graphemes(card.description.to_s, CARD_DESCRIPTION_MAX).to_s

    thumb = upload_card_image(card.image_url)
    external["thumb"] = thumb if thumb.present?

    refs = associated_refs(card)
    external["associatedRefs"] = refs if refs.any?

    { "$type" => "app.bsky.embed.external", "external" => external }
  end

  # The standard.site records of the page, as strongRefs.
  #
  # ⚠️ **This is what makes Bluesky render the standard.site card and not the ordinary one.** The
  # embed stays an `app.bsky.embed.external`, and `associatedRefs` is what it adds: the document
  # first, then the publication.
  #
  # It **falls back with no message**, on purpose. A page that publishes no `<link rel>` tag, a
  # record that this app cannot read, and a DID with a method that it cannot resolve each give an
  # empty list, and Bluesky then renders the ordinary card from the og: tags. A link to another site
  # is the usual reason.
  # @param card [OpenGraph::Card]
  # @return [Array<Hash>] The refs, in the order that the documentation gives.
  # @see https://github.com/bluesky-social/atproto/discussions/4978
  def associated_refs(card)
    document = strong_ref(card.document_uri) if card.document_uri.present?
    # ⚠️ The publication alone is not a card. That tag is on each page of the site, and the document
    # is the thing that names one article. Thus with no document this adds nothing.
    return [] if document.blank?

    publication = strong_ref(card.publication_uri) if card.publication_uri.present?
    [ document, publication ].compact
  end

  # Downloads the og:image of the link and uploads it as a blob.
  #
  # ⚠️ This is not `AtProto#upload_image_blob`, which asks the Contentful Images API for a smaller
  # copy. The picture here belongs to the page that the owner linked to, which can be another site
  # and can be a Short, which has no cover image at all.
  #
  # Each step fails soft, on purpose: a picture past `MAX_CARD_IMAGE_BYTES`, a body that is not an
  # image, and a picture that stays past the blob limit after the shrink each give nil, and the card
  # then renders with no thumbnail.
  # @param url [String, nil] The og:image.
  # @return [Hash, nil] The blob, or nil after any failure.
  def upload_card_image(url)
    picture = card_image(url)
    return if picture.nil?

    upload_blob(picture[:body], picture[:content_type])
  end

  # Makes a picture into a JPEG that fits under the blob limit.
  #
  # ⚠️ A blob past the limit fails at `putRecord`, and not at the upload. Thus without this step the
  # whole post fails, and the message names the embed and not the picture. libvips is already a
  # dependency of this app, for the blurhash placeholders.
  # @param bytes [String] The original image.
  # @return [Array(String, String), Array(nil, nil)] [bytes, mime], or [nil, nil] when it cannot.
  def shrink(bytes)
    # ⚠️ The require is **here** and not at the top of the file. libvips is a native library, and a
    # require at the top makes each path of this class need it: a post with a small picture, and
    # the preview of the Social media page, would then both fail where nothing has to shrink anything.
    # ⚠️ LoadError is not a StandardError, thus the rescue below must name it. Without that, a
    # machine with no libvips gives a 500 in place of a card with no picture.
    require "vips"

    # ⚠️ `thumbnail_buffer` shrinks at the decode. `new_from_buffer` + `resize` decodes the full
    # picture first, and an 8000×6000 og:image is then ~144MB of pixels on a 512MB machine, in the
    # request path of the preview as well as in the job. It still decodes, thus it is still the
    # check that the bytes are a picture.
    smallest = nil
    CARD_IMAGE_STEPS.each do |step|
      image = Vips::Image.thumbnail_buffer(bytes, step[:width], size: :down)
      smallest = image.jpegsave_buffer(Q: step[:quality], strip: true)
      return [ smallest, "image/jpeg" ] if smallest.bytesize <= MAX_BLOB_BYTES
    end

    # Each step was too large. The caller drops the thumbnail, and the card renders without it.
    [ smallest, "image/jpeg" ]
  rescue StandardError, LoadError => e
    report_upstream_error(e, context: "bluesky card image resize")
    [ nil, nil ]
  end

  # Makes the rich-text facets of the body: each link, each mention, and each hashtag.
  #
  # ⚠️ **Each offset comes from the PLAIN text that the record holds**, and never from the words
  # that the owner typed. `#post!` renders the Markdown one time and gives that text to this method
  # with the links of the same parse.
  #
  # ⚠️ The links come first, and a mention or a tag inside a link is not a facet. A URL such as
  # `…/profile/@me.bsky.social` or `…/#section` would otherwise get two facets over one range, and
  # a client renders that as a broken link.
  # @param text [String] The plain text.
  # @param links [Array<MarkdownLinks::Link>] The links that the Markdown made.
  # @return [Array<Hash>]
  def build_facets(text, links: [])
    facets = self.class.link_ranges(text, links).map { |link| link_facet(text, link) }
    inside_link = facets.map { |facet| facet["index"]["byteStart"]...facet["index"]["byteEnd"] }

    all = facets + mention_facets(text, skip: inside_link) + tag_facets(text, skip: inside_link)
    # ⚠️ In order of the byte offset, as the client of Bluesky writes them. The links are in order
    # already, thus a tag at byte 5 came after a link at byte 200.
    all.sort_by { |facet| facet["index"]["byteStart"] }
  end

  # ⚠️ The offsets of the record are in **bytes** of the UTF-8 text, and `MarkdownLinks::Link`
  # holds characters. One accented letter is 1 character and 2 bytes, thus a character offset moves
  # the highlight of each facet after it.
  # @param text [String]
  # @param link [MarkdownLinks::Link]
  # @return [Hash] One app.bsky.richtext.facet#link.
  def link_facet(text, link)
    {
      "index" => {
        "byteStart" => text[0...link.start].bytesize,
        "byteEnd" => text[0...link.finish].bytesize
      },
      "features" => [ { "$type" => "app.bsky.richtext.facet#link", "uri" => link.url } ]
    }
  end

  # Resolves each @handle and drops one that the PDS does not know: a facet with no DID makes the
  # record invalid.
  # @param skip [Array<Range>] The byte ranges to leave alone.
  # @return [Array<Hash>]
  def mention_facets(text, skip: [])
    scan_facets(text, MENTION_PATTERN, skip: skip) do |match|
      did = resolve_handle(match.delete_prefix("@"))
      next if did.blank?

      { "$type" => "app.bsky.richtext.facet#mention", "did" => did }
    end
  end

  # One app.bsky.richtext.facet#tag for each #hashtag.
  #
  # ⚠️ It does not use `#scan_facets`. The facet of a tag can be SHORTER than its match: the client
  # removes the punctuation at the end, thus "#trail." tags "trail" and the facet must become
  # shorter with it, or it covers a character that the tag does not hold.
  # @param text [String]
  # @param skip [Array<Range>] The byte ranges to leave alone.
  # @return [Array<Hash>]
  def tag_facets(text, skip: [])
    facets = []

    text.to_s.scan(TAG_PATTERN) do
      match = Regexp.last_match
      start_char, = match.offset(1)
      byte_start = text[0...start_char].bytesize

      tag = match[1].sub(TRAILING_PUNCTUATION, "")
      byte_end = byte_start + tag.bytesize
      next if overlaps?(byte_start, byte_end, skip)

      # The facet covers the "#", and the value of the tag does not.
      name = tag.sub(TAG_PREFIX, "")
      next if name.blank?
      next if SocialText.graphemes(name) > MAX_TAG_GRAPHEMES || name.bytesize > MAX_TAG_BYTES

      facets << {
        "index" => { "byteStart" => byte_start, "byteEnd" => byte_end },
        "features" => [ { "$type" => "app.bsky.richtext.facet#tag", "tag" => name } ]
      }
    end

    facets
  end

  # Finds each match of the first group of a pattern and makes a facet from it.
  #
  # ⚠️ The offsets are in **bytes** of the UTF-8 text, and not in characters. One accented letter
  # is 1 character and 2 bytes, thus a character offset moves the highlight of each facet after it.
  # @param text [String]
  # @param pattern [Regexp] A pattern whose first group is the thing to mark.
  # @param skip [Array<Range>] Byte ranges. A match that starts inside one is not a facet, and the
  #   block does not run for it.
  # @return [Array<Hash>] The facets. The block returns nil to drop one.
  def scan_facets(text, pattern, skip: [])
    facets = []
    text.to_s.scan(pattern) do
      match = Regexp.last_match
      start_char, end_char = match.offset(1)
      byte_start = text[0...start_char].bytesize
      byte_end = text[0...end_char].bytesize
      next if overlaps?(byte_start, byte_end, skip)

      feature = yield(match[1])
      next if feature.blank?

      facets << {
        "index" => { "byteStart" => byte_start, "byteEnd" => byte_end },
        "features" => [ feature ]
      }
    end
    facets
  end

  # ⚠️ It compares the FULL range, and not the start byte alone. A mention or a tag that starts
  # before a link and continues into it is an overlap, and two facets over one range make a client
  # render a broken link.
  # @param byte_start [Integer]
  # @param byte_end [Integer] The end of the range, not included.
  # @param skip [Array<Range>] The byte ranges to avoid.
  # @return [Boolean] True when the range touches one of them.
  def overlaps?(byte_start, byte_end, skip)
    skip.any? { |range| byte_start < range.end && range.begin < byte_end }
  end

  # @param handle [String] A handle, with no "@".
  # @return [String, nil] The DID, or nil when the PDS cannot resolve it.
  def resolve_handle(handle)
    response = resolve_handle_response(handle)
    return unless response.success?

    JSON.parse(response.body)["did"].presence
  rescue StandardError
    nil
  end

  # ⚠️ The timeout is here, thus the two callers above share it. #handle_missing? runs in a request
  # and more than one time, and RESOLVE_TIMEOUT is short for that reason.
  # @param handle [String]
  # @return [HTTParty::Response]
  def resolve_handle_response(handle)
    HTTParty.get("#{pds_url}/xrpc/com.atproto.identity.resolveHandle",
                 query: { "handle" => handle }, timeout: RESOLVE_TIMEOUT)
  end
end

# Posts to Bluesky, as the account that Connected apps holds.
#
# ⚠️ This is not `StandardSite`, which writes the `site.standard.*` mirror of the blog. This class
# writes an `app.bsky.feed.post`, and the two share the account and the session through `AtProto`.
#
# @see https://atproto.com/blog/create-post
class Bluesky < ApplicationService
  include AtProto

  COLLECTION = "app.bsky.feed.post".freeze

  # The limit of a post, in grapheme clusters. ⚠️ `SocialPresenter::BODY_LIMIT` is the same number
  # on the admin page.
  MAX_GRAPHEMES = 300

  # The limit of a post in bytes, which is the second limit of `app.bsky.feed.post#text`.
  # ⚠️ Emoji-heavy words pass the grapheme limit and fail this one, and the PDS then refuses the
  # record.
  MAX_BYTES = 3_000

  # The limits of one `app.bsky.richtext.facet#tag`. ⚠️ A tag past one of them makes the full
  # record invalid.
  MAX_TAG_GRAPHEMES = 64
  MAX_TAG_BYTES = 640

  # The largest blob that a PDS takes for a card thumbnail. ⚠️ This is the `thumb` of
  # `app.bsky.embed.external`, and not the limit of a photo, which is MAX_IMAGE_BYTES.
  MAX_BLOB_BYTES = 976_560

  # The most photos on one post. The schema of `app.bsky.embed.gallery` takes 20, and the clients
  # of Bluesky permit 10. ⚠️ `SocialNetwork::MAX_PHOTOS` is this number.
  MAX_IMAGES = 10
  # The most photos that `app.bsky.embed.images` takes. A post with more needs the gallery embed.
  MAX_IMAGES_EMBED = 4
  # The largest blob of one photo, from `app.bsky.embed.images#image` and
  # `app.bsky.embed.gallery#image`.
  MAX_IMAGE_BYTES = 2_000_000
  # The limit of the alt text of one photo, from the client of Bluesky. The lexicon has none.
  MAX_ALT_GRAPHEMES = 2000
  # The most bytes of an og:image that this class downloads. ⚠️ The worker is a 512MB VM. A
  # picture past this limit loses the thumbnail and never the post.
  MAX_CARD_IMAGE_BYTES = 10 * 1024 * 1024
  # The types of an og:image that go up with no change. Each other type goes through the shrink
  # and comes out as a JPEG. ⚠️ An SVG can hold a script, and
  # `Admin::SocialController#preview_image` sends these bytes from the admin host.
  CARD_IMAGE_TYPES = %w[image/jpeg image/png image/webp image/gif].freeze

  # The limits of the text fields of a card.
  CARD_TITLE_MAX = 300
  CARD_DESCRIPTION_MAX = 1000

  # The language of each post. This blog is in English.
  LANGS = [ "en-US" ].freeze

  # An @handle, from the sample in the AT Protocol documentation.
  MENTION_PATTERN = /(?:^|[$|\W])(@(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)/
  # A bare URL: each character up to a space. `.trim_url` then removes what belongs to the
  # sentence.
  # ⚠️ Do not change this into a list of the permitted characters. Such a list cuts
  # `…/Kona_(Hawaii)` and a path outside ASCII, and each one then links to the wrong page.
  URL_PATTERN = %r{(?:^|[$|\W])(https?://\S+)}

  # The characters that an address can end with. Each character after the last one of these
  # belongs to the sentence. ⚠️ It uses `\p{Alnum}` and not `a-z0-9`, thus a path outside ASCII
  # ends where it must.
  URL_TERMINAL = /[\p{Alnum}\-_~\/\#@$&*+=%]/

  # The characters that close something that holds the address. One of them ends an address only
  # when the address opened it.
  URL_WRAPPERS = { ")" => "(", "]" => "[", ">" => "<", "}" => "{" }.freeze
  # The zero-width and formatting characters that a tag cannot hold, from the tag rule of the
  # Bluesky client.
  TAG_EXCLUDED = "\u00AD\u2060\u200A\u200B\u200C\u200D\u20E2".freeze

  # A #hashtag, from the rule of the Bluesky client, thus a facet covers the same characters that
  # a reader sees tagged.
  # ⚠️ It does not use `\w`, which is ASCII in Ruby and cuts "#café" to "caf". It needs one
  # character that is not a digit and not punctuation, which keeps "#1" a number.
  TAG_PATTERN = /(?:^|\s)([#＃](?!\uFE0F)[^\s#{TAG_EXCLUDED}]*[^\d\s\p{P}#{TAG_EXCLUDED}]+[^\s#{TAG_EXCLUDED}]*)/

  TAG_PREFIX = /\A[#＃]/

  # The client removes the punctuation at the end of a tag, thus "#trail." tags "trail".
  TRAILING_PUNCTUATION = /\p{P}+\z/

  # The number of grapheme clusters in a post, as Bluesky counts them. `social_post_controller.js`
  # counts the same way in the browser.
  #
  # ⚠️ It renders the Markdown first, because the record holds the rendered text. The address of
  # a link is in a facet, thus `[my post](https://example.com/a)` is 7 characters and not 30.
  # @param text [String, nil]
  # @return [Integer]
  def self.post_length(text)
    SocialText.graphemes(MarkdownLinks.render(text))
  end

  # ⚠️ It reads the graphemes and the bytes, because the lexicon has both limits.
  # @param text [String, nil]
  # @return [Boolean] True when the text fits in one post and is not empty.
  def self.valid_post_length?(text)
    plain = MarkdownLinks.render(text)
    length = SocialText.graphemes(plain)
    length.positive? && length <= MAX_GRAPHEMES && plain.bytesize <= MAX_BYTES
  end

  # Each link of a post, in order, as CHARACTER offsets into the plain text.
  #
  # ⚠️ This is the one list: `#build_facets` makes a facet from each entry, and the preview of the
  # Social media page renders each entry as an `<a>`. Thus the two cannot disagree.
  # @param text [String, nil] The PLAIN text, which `MarkdownLinks.render` makes.
  # @param markdown [Array<MarkdownLinks::Link>] The links that the Markdown made, from the same
  #   parse that made the text.
  # @return [Array<MarkdownLinks::Link>]
  def self.link_ranges(text, markdown = [])
    text = text.to_s
    taken = markdown.map { |link| link.start...link.finish }
    bare = []

    SocialText.url_ranges(text).each do |range|
      # ⚠️ A bare URL that touches a Markdown link is not a second link: two link facets over one
      # range make a client render a broken link. Compare the full range, and not its start alone.
      next if taken.any? { |other| range.begin < other.end && other.begin < range.end }

      # `SocialText.url_ranges` removed the punctuation of the sentence already.
      bare << MarkdownLinks::Link.new(start: range.begin, finish: range.end, url: text[range])
    end

    (markdown + bare).sort_by(&:start)
  end

  # Removes the punctuation of the sentence from the end of an address, as the client of Bluesky
  # does.
  def self.trim_url(url)
    url = url.to_s
    url = url[0...-1] while url.present? && !url_ends_here?(url)
    url
  end

  # @param url [String] The candidate address.
  # @return [Boolean] True when the last character belongs to the address.
  def self.url_ends_here?(url)
    last = url[-1]
    return true if URL_TERMINAL.match?(last)

    # ⚠️ A closing bracket belongs to the address only when the address opened it, thus
    # `…/Kona_(Hawaii)` keeps its bracket and `(see …/a)` gives up the one that closes the aside.
    opener = URL_WRAPPERS[last]
    opener.present? && url.count(opener) >= url.count(last)
  end

  # @param handle [String] The handle of the account.
  # @param rkey [String] The record key.
  # @return [String] The public URL of the post.
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
  # second attempt of the same job replaces the same record and does not add a second post. Make
  # the key with `Bluesky.new_tid` before you add the job.
  #
  # @param rkey [String] The record key, from `Bluesky.new_tid`.
  # @param text [String] The body of the post.
  # @param card [OpenGraph::Card, nil] The card of the link, from `OpenGraph#fetch`. Nil gives a
  #   post with no card. ⚠️ Give a card that is `embeddable?` only: a card with no title, no
  #   description, and no picture renders as an empty box.
  # @param reply [Hash, nil] `{ "root" =>, "parent" => }`, each a reference from an earlier call.
  #   The root is the first post of the thread, and the parent is the post above this one.
  # @param photos [Array<Hash>] `[{ bytes:, width:, height:, alt: }, …]`, each a JPEG below
  #   MAX_IMAGE_BYTES. ⚠️ A post takes photos or a card, and not both: the record holds one embed.
  # @return [Hash] `{ "uri" =>, "cid" =>, "url" => }`. The next post of a thread names this one with
  #   the `uri` and the `cid`.
  # @raise [ApplicationJob::PermanentError] When no account is connected, or when the text or the
  #   photos do not fit. The job does not run again.
  # @raise [RuntimeError] When the session, a photo upload, or the write fails. `BlueskyPostJob`
  #   then does the work again.
  def post!(rkey:, text:, card: nil, reply: nil, photos: [])
    raise ArgumentError, "A post takes a card or photos, and not both" if card.present? && photos.present?
    raise ApplicationJob::PermanentError, "Bluesky is not connected" unless valid_credentials?
    raise ApplicationJob::PermanentError, "The post is empty or longer than #{MAX_GRAPHEMES} characters" unless self.class.valid_post_length?(text)
    raise ApplicationJob::PermanentError, "A post takes at most #{MAX_IMAGES} photos" if photos.length > MAX_IMAGES
    raise "Could not open a Bluesky session" unless open_session(handle: @handle, app_password: @app_password)

    # ⚠️ The Markdown is rendered here, and not in the action. The plain words and the facet of
    # each link must come from one parse.
    post = MarkdownLinks.parse(text)

    record = {
      "$type" => COLLECTION,
      "text" => post.text,
      "langs" => LANGS,
      # ⚠️ Milliseconds: two posts of one thread go out inside the same second, and the AppView
      # sorts an author feed by this value.
      # ⚠️ The time comes from the record key, thus each attempt writes the same bytes and the CID
      # does not change. A new CID would break the `parent` of a reply that is already published.
      "createdAt" => (self.class.tid_time(rkey) || Time.now).utc.iso8601(3)
    }
    facets = build_facets(post.text, links: post.links)
    record["facets"] = facets if facets.any?
    embed = photos.present? ? build_images_embed(photos) : build_card(card)
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
  # ⚠️ This is public because the Social media preview proxies it: the CSP of the admin has
  # `img-src :self`. Thus the preview shows the exact bytes that this class uploads.
  #
  # Each step fails soft: a picture past `MAX_CARD_IMAGE_BYTES`, a body that is not an image, and
  # a decode that fails each give nil. A card with no picture still renders.
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
    mime = picture[:content_type].to_s.split(";").first.to_s.strip.downcase

    # ⚠️ The shrink decodes the bytes with libvips, thus it is also the check that they are an
    # image. A host with no content type, or a 200 that is an HTML error page, must not go up.
    bytes, mime = shrink(bytes) if !CARD_IMAGE_TYPES.include?(mime) || bytes.bytesize > MAX_BLOB_BYTES
    return if bytes.blank? || bytes.bytesize > MAX_BLOB_BYTES

    { body: bytes, content_type: mime }
  rescue StandardError => e
    report_upstream_error(e, context: "bluesky card image", url: url)
    nil
  end

  # Asks the PDS if a handle exists.
  #
  # ⚠️ It answers true only for a definite refusal. A PDS that is away, slow, or broken gives
  # false, thus an outage there never stops a post to Mastodon and Threads.
  # ⚠️ `#resolve_handle` cannot answer this question: it gives nil for "no such handle" and for
  # "no answer".
  # @param handle [String, nil] A handle, with no "@".
  # @return [Boolean]
  def handle_missing?(handle)
    return false if handle.blank?
    # A handle whose DID is in the cache resolved a moment ago, and the PDS needs no question.
    return false if $redis.exists?(did_key(handle))

    response = resolve_handle_response(handle)
    # A PDS answers 400 InvalidRequest for a handle that it cannot resolve.
    response.code == 400
  rescue StandardError
    false
  end

  private

  # @return [String] The name of this client in each log line of AtProto.
  def at_proto_label = "bluesky"

  # Makes the website card of the link. The link is this card and is not in the text, thus the
  # URL uses none of the 300 characters. A failure of the image loses the picture only.
  # @param card [OpenGraph::Card, nil] An `embeddable?` card. Refer to #post!.
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

  # Makes the embed of the photos.
  #
  # ⚠️ Two embed types. A post of MAX_IMAGES_EMBED photos or fewer keeps `app.bsky.embed.images`,
  # because an old client renders nothing for `app.bsky.embed.gallery`. Each item of a gallery
  # carries its `$type`, and an item of the images embed does not.
  #
  # ⚠️ It raises when one upload fails, and the job does the work again. A post with three of its
  # four photos is not the post that the owner wrote.
  # @param photos [Array<Hash>] `[{ bytes:, width:, height:, alt: }, …]`
  # @return [Hash] An app.bsky.embed.images or an app.bsky.embed.gallery.
  def build_images_embed(photos)
    items = photos.map do |photo|
      blob = upload_blob(photo[:bytes], "image/jpeg")
      raise "Could not upload a photo of the post" if blob.blank?

      { "image" => blob,
        "alt" => truncate_graphemes(photo[:alt].to_s, MAX_ALT_GRAPHEMES).to_s,
        "aspectRatio" => { "width" => photo[:width].to_i, "height" => photo[:height].to_i } }
    end

    if items.length <= MAX_IMAGES_EMBED
      { "$type" => "app.bsky.embed.images", "images" => items }
    else
      { "$type" => "app.bsky.embed.gallery",
        "items" => items.map { |item| { "$type" => "app.bsky.embed.gallery#image" }.merge(item) } }
    end
  end

  # The standard.site records of the page, as strongRefs: the document first, then the
  # publication.
  #
  # ⚠️ `associatedRefs` is what makes Bluesky render the standard.site card and not the ordinary
  # one. A page with no `<link rel>` tag, or a record that this app cannot read, gives an empty
  # list, and Bluesky then renders the ordinary card.
  # @param card [OpenGraph::Card]
  # @return [Array<Hash>]
  # @see https://github.com/bluesky-social/atproto/discussions/4978
  def associated_refs(card)
    document = strong_ref(card.document_uri) if card.document_uri.present?
    # ⚠️ The publication alone is not a card: that tag is on each page of the site. Thus with no
    # document this adds nothing.
    return [] if document.blank?

    publication = strong_ref(card.publication_uri) if card.publication_uri.present?
    [ document, publication ].compact
  end

  # Splits an `at://` URI into its three parts.
  # @param uri [String, nil]
  # @return [Array(String, String, String), nil] [did, collection, rkey], or nil for a URI with
  #   another shape.
  def parse_at_uri(uri)
    match = uri.to_s.match(%r{\Aat://(?<did>[^/]+)/(?<collection>[^/]+)/(?<rkey>[^/?\#]+)\z})
    return if match.nil?

    [ match[:did], match[:collection], match[:rkey] ]
  end

  # Reads one record and makes a `com.atproto.repo.strongRef` of it.
  #
  # ⚠️ A strongRef needs the CID, and an `at://` URI does not hold one, thus the code must read
  # the record. The CID changes at each write, thus do not cache this for a long time.
  # @param uri [String] An at:// URI.
  # @return [Hash, nil] `{ "uri" =>, "cid" => }`, or nil when the record cannot be read.
  def strong_ref(uri)
    did, collection, rkey = parse_at_uri(uri)
    return if did.blank?

    service = service_for(did)
    return if service.blank?

    record = get_json("#{service}/xrpc/com.atproto.repo.getRecord",
                      query: { repo: did, collection: collection, rkey: rkey },
                      timeout: REQUEST_TIMEOUT)
    return if record.blank? || record[:cid].blank?

    { "uri" => record[:uri].presence || uri, "cid" => record[:cid] }
  rescue StandardError => e
    report_upstream_error(e, context: "#{at_proto_label} getRecord")
    nil
  end

  # The host that holds a repo.
  #
  # ⚠️ A PDS answers `getRecord` for its own repos only, thus a DID that is not ours needs its DID
  # document first. `did:plc` resolves at the directory, and each other method gives nil.
  # @return [String, nil]
  def service_for(did)
    return @service_url if did == @did && @service_url.present?
    return unless did.start_with?("did:plc:")

    doc = get_json("https://plc.directory/#{did}", symbolize: false, timeout: REQUEST_TIMEOUT)
    pds_endpoint_from_did_doc(doc)
  end

  # Downloads the og:image of the link and uploads it as a blob. Each failure gives nil, and the
  # card then renders with no thumbnail.
  #
  # ⚠️ This is not `AtProto#upload_image_blob`, which asks the Contentful Images API for a smaller
  # copy. The picture here can belong to another site.
  # @param url [String, nil] The og:image.
  # @return [Hash, nil] The blob, or nil after any failure.
  def upload_card_image(url)
    picture = card_image(url)
    return if picture.nil?

    upload_blob(picture[:body], picture[:content_type])
  end

  # Makes a picture into a JPEG that fits under the blob limit of a card thumbnail.
  #
  # ⚠️ A blob past the limit fails at `putRecord`, and not at the upload. Thus without this step the
  # whole post fails, and the message names the embed and not the picture.
  # @param bytes [String] The original image.
  # @return [Array(String, String), Array(nil, nil)] [bytes, mime], or [nil, nil] when it cannot.
  def shrink(bytes)
    shrink_image(bytes, limit: MAX_BLOB_BYTES)
  end

  # Makes the rich-text facets of the body: each link, each mention, and each hashtag.
  #
  # ⚠️ Each offset comes from the PLAIN text that the record holds, and never from the words that
  # the owner typed.
  # @param text [String] The plain text.
  # @param links [Array<MarkdownLinks::Link>] The links that the Markdown made.
  # @return [Array<Hash>]
  def build_facets(text, links: [])
    facets = self.class.link_ranges(text, links).map { |link| link_facet(text, link) }

    # ⚠️ Each kind gives way to the kinds before it, thus no two facets cover one byte: two facets
    # over one range make a client render a broken link. A mention comes before a tag because
    # `#tag.@example.com` matches the two patterns.
    facets += mention_facets(text, skip: byte_ranges(facets))
    facets += tag_facets(text, skip: byte_ranges(facets))

    # ⚠️ In order of the byte offset, as the client of Bluesky writes them.
    facets.sort_by { |facet| facet["index"]["byteStart"] }
  end

  # @param facets [Array<Hash>] The facets so far.
  # @return [Array<Range>] Their byte ranges.
  def byte_ranges(facets)
    facets.map { |facet| facet["index"]["byteStart"]...facet["index"]["byteEnd"] }
  end

  # ⚠️ The offsets of the record are in bytes of the UTF-8 text, and `MarkdownLinks::Link` holds
  # characters. One accented letter is 1 character and 2 bytes.
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
  # ⚠️ It does not use `#scan_facets`, because the facet of a tag can be shorter than its match:
  # "#trail." tags "trail", and the facet must not cover the full stop.
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

  # Finds each match of the first group of a pattern and makes a facet from it, with byte
  # offsets. Refer to #link_facet.
  # @param pattern [Regexp] A pattern whose first group is the thing to mark.
  # @param skip [Array<Range>] Byte ranges. A match that touches one is not a facet, and the block
  #   does not run for it.
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

  # ⚠️ It compares the full range, and not the start byte alone: a mention that starts before a
  # link and continues into it is an overlap.
  # @param byte_end [Integer] The end of the range, not included.
  # @return [Boolean] True when the range touches one of `skip`.
  def overlaps?(byte_start, byte_end, skip)
    skip.any? { |range| byte_start < range.end && range.begin < byte_end }
  end

  # The time that the DID of a handle stays in Redis. ⚠️ A handle that moves to another DID
  # inside that time tags the old account, and that is rare.
  DID_CACHE_TTL = 1.day

  # @param handle [String] A handle, with no "@".
  # @return [String, nil] The DID, or nil when the PDS cannot resolve it.
  def resolve_handle(handle)
    cached_json(did_key(handle), expires_in: DID_CACHE_TTL) do
      response = resolve_handle_response(handle)
      next unless response.success?

      did = JSON.parse(response.body)["did"].presence
      { did: did } if did
    end&.dig(:did)
  rescue StandardError
    nil
  end

  # @param handle [String]
  # @return [String] The Redis key of the DID of a handle.
  def did_key(handle) = "bluesky:did:#{handle.to_s.downcase}"

  # ⚠️ The timeout is here, thus the two callers share it. #handle_missing? runs in a request,
  # and RESOLVE_TIMEOUT is short for that reason.
  # @return [HTTParty::Response]
  def resolve_handle_response(handle)
    HTTParty.get("#{pds_url}/xrpc/com.atproto.identity.resolveHandle",
                 query: { "handle" => handle }, timeout: RESOLVE_TIMEOUT)
  end
end

module UrlHelpers
  # Constructs the full URL for a given Middleman resource, depending on the environment.
  # @param resource [Object] The resource for which the URL is being generated.
  # @param params [Hash] (Optional) Additional query parameters to be included in the URL.
  # @return [String] The fully constructed URL as a string.
  def full_url(resource, params = {})
    url = URI.parse(root_url)
    url.path = url_for(resource)
    url.query = URI.encode_www_form(params) if params.present?
    url.to_s
  end

  # Constructs the full URL for a link in an Atom feed, carrying the attribution params
  # Plausible reads: `utm_source` becomes the Source, `utm_medium` the Medium (filter on
  # `feed` for the all-feeds rollup), and `utm_campaign` the per-tag breakdown on tag feeds.
  #
  # `utm_source` is a placeholder: the feed-source edge function
  # (web/netlify/edge-functions/feed-source.ts) rewrites it to the fetching reader's name at
  # request time, since the user agent is only knowable then. It stays "Feed" for readers we
  # don't recognize, which also keeps continuity with the historical `ref=Feed` Source.
  #
  # ⚠️ `utm_source` MUST be emitted first: the edge function anchors its substitution on the
  # literal `utm_source=Feed&`, so reordering these keys silently breaks the rewrite.
  # @param resource [Object] The resource for which the URL is being generated.
  # @param campaign [String, nil] (Optional) The tag id for a tag feed; omitted on the main feed.
  # @return [String] The fully constructed URL as a string.
  def feed_url(resource, campaign: nil)
    params = { utm_source: 'Feed', utm_medium: 'feed' }
    params[:utm_campaign] = campaign if campaign.present?
    full_url(resource, params)
  end

  # Returns the root URL of the application based on the environment.
  # In production, it uses the site URL set by Netlify.
  # On other Netlify environments (like dev and branch previews), it uses the 'DEPLOY_URL' environment variable.
  # Outside of Netlify, like running `middleman server`, defaults to 'http://localhost:4567'.
  # @see https://docs.netlify.com/configure-builds/environment-variables/#deploy-urls-and-metadata
  # @return [String] The root URL of the application.
  def root_url
    if production?
      ENV['URL']
    elsif netlify?
      ENV['DEPLOY_URL']
    else
      'http://localhost:4567'
    end
  end
end

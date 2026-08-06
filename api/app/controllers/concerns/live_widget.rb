# Shared behavior for the live-updating widget endpoints embedded in the static site: public
# HTTP caching headers, and the empty-body "no data" response that collapses a widget.
module LiveWidget
  extend ActiveSupport::Concern

  # How long the edge may serve a stale fragment while revalidating. Kept short by default —
  # this is a low-traffic site, so a long window mostly means serving badly stale data rather
  # than smoothing load. Widgets whose data barely changes override it up to a day.
  DEFAULT_EDGE_STALE_WHILE_REVALIDATE = 1.hour
  # How long the edge may serve a stale fragment when the origin 5xxes. Together with
  # stale-while-revalidate, this is what keeps widgets rendering through a fly outage.
  EDGE_STALE_IF_ERROR = 1.day

  private

  # Sets an embedded fragment's caching policy, decoupling browser freshness from edge
  # freshness: the browser is told the fragment is immediately stale but may serve its cached
  # copy while revalidating against the cheap edge, and the edge keeps it fresh for `ttl`.
  #
  # Never express the edge policy as `s-maxage`: its presence disables both
  # stale-while-revalidate and stale-if-error (RFC 9111 §4.2.4), which is the resilience these
  # directives exist to provide.
  # @param ttl [ActiveSupport::Duration] How long the fragment stays fresh at the edge.
  # @param stale_while_revalidate [ActiveSupport::Duration] The browser's revalidation grace
  #   window.
  # @param edge_stale_while_revalidate [ActiveSupport::Duration] The edge's stale-serving window.
  def cache_widget(ttl:, stale_while_revalidate: ttl, edge_stale_while_revalidate: DEFAULT_EDGE_STALE_WHILE_REVALIDATE)
    # max-age=0, not no-cache, so stale-while-revalidate still applies in the browser.
    expires_in 0, public: true, stale_while_revalidate: stale_while_revalidate
    # CDN-Cache-Control (RFC 9213) is honored by Cloudflare and ignored by browsers, which is
    # what lets the edge TTL differ from the browser's max-age=0 above.
    edge_policy =
      "max-age=#{ttl.to_i}, " \
      "stale-while-revalidate=#{edge_stale_while_revalidate.to_i}, " \
      "stale-if-error=#{EDGE_STALE_IF_ERROR.to_i}"
    response.headers["CDN-Cache-Control"] = "public, #{edge_policy}"
  end

  # How long an empty "no data" response stays cached. Short, so a momentary origin blip
  # doesn't pin an empty widget for the full data TTL, but not zero, so a sustained outage
  # doesn't hammer the single origin machine.
  EMPTY_TTL = 1.minute

  # Renders the empty body that signals "no data", which makes the live-update controller
  # remove the placeholder and collapse the widget.
  def render_empty
    response.headers["CDN-Cache-Control"] = "public, max-age=#{EMPTY_TTL.to_i}"
    render plain: ""
  end

  # Runs the standard widget-action shape: set the cache policy, fetch the data, and render the
  # view — or the empty "no data" body when the block's result is blank. Actions with several
  # ivars and bail points keep the explicit cache_widget/render_empty calls instead.
  # @param view [Symbol] The view to render on success.
  # @param ttl [ActiveSupport::Duration] How long the fragment stays fresh at the edge.
  # @param cache_opts [Hash] Passed through to cache_widget.
  # @yieldreturn [Object] The widget's data; a blank result collapses the widget.
  def render_widget(view, ttl:, **cache_opts)
    cache_widget(ttl: ttl, **cache_opts)
    return render_empty if yield.blank?

    render view
  end
end

# Shared behavior for the live-updating widget endpoints embedded in the static site:
# public HTTP caching headers, and an empty-body response that signals "no data" — the
# site's live-update Stimulus controller removes the placeholder so the widget collapses.
module LiveWidget
  extend ActiveSupport::Concern

  # How long the edge may keep serving a stale fragment while it revalidates against a
  # slow/cold or failing origin. While the background revalidation is slow OR fails,
  # the edge keeps serving the last good fragment for this window — which is what actually
  # provides the down-origin resilience (the widgets keep rendering even if the single fly.io
  # machine is briefly down or cold-starting from zero).
  #
  # Kept short by default: this is a low-traffic site, so a long window mostly means the few
  # people who do see a widget get served hours- or day-old data while the background
  # revalidation lags, rather than meaningfully smoothing load. One hour balances some
  # outage resilience against not serving badly stale data. Widgets whose data barely changes
  # (upcoming races, trending/related articles) override this back up to a day, where freshness
  # doesn't matter.
  DEFAULT_EDGE_STALE_WHILE_REVALIDATE = 1.hour
  # How long the edge may keep serving a stale fragment when the origin returns an error.
  # Cloudflare honors `stale-if-error` and triggers it on a 5xx (a 404 is not an error for
  # this purpose — it replaces the cached copy). Together with stale-while-revalidate above,
  # this is what keeps the widgets rendering through a fly outage.
  # ⚠️ Both directives are disabled outright by `s-maxage`, `must-revalidate`, or
  # `proxy-revalidate` (RFC 9111 §4.2.4) — see the warning in cache_widget — and by the zone's
  # Always Online setting.
  EDGE_STALE_IF_ERROR = 1.day

  private

  # Sets the caching policy for an embedded widget fragment, decoupling browser freshness
  # from edge freshness:
  #  - The browser is told the fragment is immediately stale (max-age=0) but may serve the
  #    cached copy while revalidating in the background. Because the widgets are fetched from
  #    a same-origin proxy backed by an edge cache, that revalidation hits the cheap edge, so
  #    the live-update widgets actually refresh on visibilitychange instead of sitting on a
  #    browser-cached copy for `ttl`.
  #  - The edge keeps the fragment fresh for `ttl` (the data cadence), then serves it stale
  #    for up to a day while revalidating the origin. The whole edge policy is authored here
  #    rather than in the proxy so the cache behavior reads in one place: the web Worker's
  #    proxy (web/src/api-proxy.ts) makes the widget paths cacheable and lets this header set
  #    the TTL, re-deriving nothing.
  # @param ttl [ActiveSupport::Duration] How long the fragment stays fresh at the edge.
  # @param stale_while_revalidate [ActiveSupport::Duration] The browser's revalidation grace
  #   window; defaults to `ttl` so one value drives both browser swr and edge max-age.
  # @param edge_stale_while_revalidate [ActiveSupport::Duration] How long the edge keeps
  #   serving a stale fragment while revalidating; defaults to DEFAULT_EDGE_STALE_WHILE_REVALIDATE.
  def cache_widget(ttl:, stale_while_revalidate: ttl, edge_stale_while_revalidate: DEFAULT_EDGE_STALE_WHILE_REVALIDATE)
    # max-age=0 (NOT no-cache) so stale-while-revalidate still applies in the browser.
    expires_in 0, public: true, stale_while_revalidate: stale_while_revalidate
    # The edge policy goes in CDN-Cache-Control (RFC 9213), which Cloudflare honors and which
    # the browser ignores — that's what lets the edge TTL differ from the browser's max-age=0
    # above. ⚠️ Never express this as s-maxage: its mere presence disables
    # stale-while-revalidate AND stale-if-error (RFC 9111 §4.2.4) — the resilience these
    # directives exist to provide.
    edge_policy =
      "max-age=#{ttl.to_i}, " \
      "stale-while-revalidate=#{edge_stale_while_revalidate.to_i}, " \
      "stale-if-error=#{EDGE_STALE_IF_ERROR.to_i}"
    response.headers["CDN-Cache-Control"] = "public, #{edge_policy}"
  end

  # An empty body signals "no data" rather than real markup. The live-update controller
  # removes the placeholder on an empty response, collapsing the widget rather than leaving a
  # stuck loading skeleton. cache_widget already set the full-length policy; downgrade it here
  # (short, and with no stale-serving directives) so a momentary origin blip doesn't pin an
  # empty response for the whole data TTL — fresh page loads get real data within EMPTY_TTL
  # instead of a collapsed widget for up to an hour. Still short-cached so a sustained outage
  # doesn't hammer the single origin machine. (Only the edge header needs downgrading; the
  # browser Cache-Control is already max-age=0.)
  EMPTY_TTL = 1.minute

  def render_empty
    response.headers["CDN-Cache-Control"] = "public, max-age=#{EMPTY_TTL.to_i}"
    render plain: ""
  end

  # Runs the standard widget-action shape in one call: set the cache policy, fetch the data
  # (the block), and render the view — or the empty "no data" body when the block's result is
  # blank. Actions with several ivars and bail points (weather, events, plausible) keep the
  # explicit cache_widget/render_empty calls instead.
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

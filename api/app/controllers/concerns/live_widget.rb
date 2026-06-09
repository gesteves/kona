# Shared behavior for the live-updating widget endpoints embedded in the static site:
# public HTTP caching headers, and an empty-body response that signals "no data" — the
# site's live-update Stimulus controller removes the placeholder so the widget collapses.
module LiveWidget
  extend ActiveSupport::Concern

  # How long Netlify's durable edge may keep serving a stale fragment while it revalidates
  # against a slow/cold or failing origin. While the background revalidation is slow OR fails,
  # the edge keeps serving the last good fragment for this window — which is what actually
  # provides the down-origin resilience (the widgets keep rendering even if the single fly.io
  # machine is briefly down or cold-starting from zero).
  #
  # Kept short by default: this is a low-traffic site, so a long window mostly means the few
  # people who do see a widget get served hours- or day-old data while the background
  # revalidation lags, rather than meaningfully smoothing load. One hour balances some
  # outage resilience against not serving badly stale data. Widgets whose data barely changes
  # (pageviews, upcoming races) override this back up to a day, where freshness doesn't matter.
  DEFAULT_EDGE_STALE_WHILE_REVALIDATE = 1.hour
  # `stale-if-error` is included aspirationally: it documents the intent (keep serving stale
  # on an origin error) but Netlify's CDN currently ignores it — it's not in Netlify's list of
  # supported Netlify-CDN-Cache-Control directives, and that header isn't passed downstream to
  # anything that would honor it. The resilience above comes from stale-while-revalidate, not
  # this. Kept so the directive activates automatically if Netlify ever adds support.
  EDGE_STALE_IF_ERROR = 1.day

  private

  # Sets the caching policy for an embedded widget fragment, decoupling browser freshness
  # from edge freshness:
  #  - The browser is told the fragment is immediately stale (max-age=0) but may serve the
  #    cached copy while revalidating in the background. With the same-origin durable-edge
  #    proxy, that revalidation hits the cheap edge, so the live-update widgets actually
  #    refresh on visibilitychange instead of sitting on a browser-cached copy for `ttl`.
  #  - The edge keeps the fragment fresh for `ttl` (the data cadence), then serves it stale
  #    for up to a day while revalidating the origin. This is the complete Netlify
  #    durable-cache policy; the api-proxy function forwards it verbatim (only dropping it on
  #    non-2xx). It lives here rather than in the proxy so the whole cache policy reads in one
  #    place.
  # @param ttl [ActiveSupport::Duration] How long the fragment stays fresh at the edge.
  # @param stale_while_revalidate [ActiveSupport::Duration] The browser's revalidation grace
  #   window; defaults to `ttl` so one value drives both browser swr and edge max-age.
  # @param edge_stale_while_revalidate [ActiveSupport::Duration] How long the edge keeps
  #   serving a stale fragment while revalidating; defaults to DEFAULT_EDGE_STALE_WHILE_REVALIDATE.
  def cache_widget(ttl:, stale_while_revalidate: ttl, edge_stale_while_revalidate: DEFAULT_EDGE_STALE_WHILE_REVALIDATE)
    # max-age=0 (NOT no-cache) so stale-while-revalidate still applies in the browser.
    expires_in 0, public: true, stale_while_revalidate: stale_while_revalidate
    response.headers["Netlify-CDN-Cache-Control"] =
      "public, durable, max-age=#{ttl.to_i}, " \
      "stale-while-revalidate=#{edge_stale_while_revalidate.to_i}, " \
      "stale-if-error=#{EDGE_STALE_IF_ERROR.to_i}"
  end

  # An empty body signals "no data" rather than real markup. The live-update controller
  # removes the placeholder on an empty response, collapsing the widget rather than leaving a
  # stuck loading skeleton. cache_widget already set the full durable policy; downgrade it
  # here (short, non-durable) so a momentary origin blip doesn't pin an empty response for the
  # whole data TTL — fresh page loads get real data within EMPTY_TTL instead of a collapsed
  # widget for up to an hour. Still short-cached so a sustained outage doesn't hammer the
  # single origin machine. (Only the edge header needs downgrading; the browser Cache-Control
  # is already max-age=0.)
  EMPTY_TTL = 1.minute

  def render_empty
    response.headers["Netlify-CDN-Cache-Control"] = "public, max-age=#{EMPTY_TTL.to_i}"
    render plain: ""
  end
end

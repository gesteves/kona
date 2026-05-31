# Shared behavior for the live-updating widget endpoints embedded in the static site:
# public HTTP caching headers, and an empty-body response the site's live-update Stimulus
# controller treats as a no-op (leaving the existing markup in place).
module LiveWidget
  extend ActiveSupport::Concern

  # How long Netlify's durable edge may keep serving a stale fragment while it revalidates
  # against a slow/cold origin (swr) or recovers from a failing one (sie). Deliberately long
  # so the widgets keep rendering even if the single fly.io machine is briefly down or
  # cold-starting from zero.
  EDGE_STALE_WHILE_REVALIDATE = 1.day
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
  def cache_widget(ttl:, stale_while_revalidate: ttl)
    # max-age=0 (NOT no-cache) so stale-while-revalidate still applies in the browser.
    expires_in 0, public: true, stale_while_revalidate: stale_while_revalidate
    response.headers["Netlify-CDN-Cache-Control"] =
      "public, durable, max-age=#{ttl.to_i}, " \
      "stale-while-revalidate=#{EDGE_STALE_WHILE_REVALIDATE.to_i}, " \
      "stale-if-error=#{EDGE_STALE_IF_ERROR.to_i}"
  end

  # Renders an empty body. The live-update controller no-ops on it, leaving the existing
  # markup in place rather than blanking the widget when data is unavailable.
  def render_empty
    render plain: ""
  end

  # Marks the response as uncacheable (Cache-Control: no-store), for endpoints that must
  # always serve a fresh value.
  def no_store!
    response.cache_control[:no_store] = true
  end
end

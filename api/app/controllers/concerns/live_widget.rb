# The shared behavior of the live-update widget endpoints in the static site: the public HTTP cache
# headers, and the response with an empty body that means "no data" and removes a widget.
module LiveWidget
  extend ActiveSupport::Concern

  # The time that the edge can serve an old fragment while it gets a new one. The default is short,
  # because this site has low traffic. Thus a long window gives very old data and does not make the
  # load smooth. A long window also keeps a markup change out of some PoPs for that full time.
  DEFAULT_EDGE_STALE_WHILE_REVALIDATE = 1.hour
  # The time that the edge can serve an old fragment when the origin gives a 5xx. With
  # stale-while-revalidate, this is what keeps the widgets on the page through a fly failure.
  EDGE_STALE_IF_ERROR = 1.day

  private

  # Sets the cache policy of a fragment in a page. It separates the freshness in the browser from
  # the freshness at the edge: the fragment is old for the browser immediately, but the browser can
  # show its cached copy while it gets a new one from the edge, which is fast. The edge keeps the
  # fragment fresh for `ttl`.
  #
  # Never write the edge policy as `s-maxage`. That directive stops both stale-while-revalidate and
  # stale-if-error (RFC 9111 §4.2.4), and those two give the protection that this method needs.
  # @param ttl [ActiveSupport::Duration] The time that the fragment stays fresh at the edge.
  # @param stale_while_revalidate [ActiveSupport::Duration] The extra time for the browser to get a
  #   new copy.
  # @param edge_stale_while_revalidate [ActiveSupport::Duration] The time that the edge can serve an
  #   old copy.
  def cache_widget(ttl:, stale_while_revalidate: ttl, edge_stale_while_revalidate: DEFAULT_EDGE_STALE_WHILE_REVALIDATE)
    # Use max-age=0, and not no-cache, thus stale-while-revalidate still applies in the browser.
    expires_in 0, public: true, stale_while_revalidate: stale_while_revalidate
    # Cloudflare obeys CDN-Cache-Control (RFC 9213) and a browser ignores it. That is what lets the
    # edge TTL be different from the max-age=0 of the browser above.
    edge_policy =
      "max-age=#{ttl.to_i}, " \
      "stale-while-revalidate=#{edge_stale_while_revalidate.to_i}, " \
      "stale-if-error=#{EDGE_STALE_IF_ERROR.to_i}"
    response.headers["CDN-Cache-Control"] = "public, #{edge_policy}"
  end

  # The time that the cache keeps an empty "no data" response. It is short, thus a short problem at
  # the origin does not keep an empty widget for the full data TTL. It is not zero, thus a long
  # failure does not send many requests to the one origin machine.
  EMPTY_TTL = 1.minute

  # Renders the empty body that means "no data". The live-update controller then removes the
  # placeholder and the widget goes away.
  def render_empty
    response.headers["CDN-Cache-Control"] = "public, max-age=#{EMPTY_TTL.to_i}"
    render plain: ""
  end

  # Does the standard steps of a widget action: it sets the cache policy, gets the data, and
  # renders the view. If the result of the block is blank, it renders the empty "no data" body. An
  # action with more than one instance variable and more than one exit keeps its own cache_widget
  # and render_empty calls.
  # @param view [Symbol] The view to render on a success.
  # @param ttl [ActiveSupport::Duration] The time that the fragment stays fresh at the edge.
  # @param cache_opts [Hash] The options that go to cache_widget.
  # @yieldreturn [Object] The data of the widget. A blank result removes the widget.
  def render_widget(view, ttl:, **cache_opts)
    cache_widget(ttl: ttl, **cache_opts)
    return render_empty if yield.blank?

    render view
  end
end

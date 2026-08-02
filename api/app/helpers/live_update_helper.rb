module LiveUpdateHelper
  # The URL the embedded markup should refetch itself from on visibilitychange.
  #
  # ⚠️ The fragment's outer element must repeat the web placeholder's attribute cluster
  # (`data-controller="live-update"`, this url value, the visibilitychange `data-action`) — but
  # NOT `data-live-update-placeholder-value`. That flag means "I'm an empty skeleton": it makes
  # the element fetch on connect and, crucially, delete itself when a fetch fails. On a fragment
  # holding real content that would destroy the rendering on any transient blip. See the
  # cross-app HTML contract in the root CLAUDE.md.
  #
  # Intentionally relative (just the request path): the markup is embedded into the static
  # site and re-fetched through a same-origin proxy that caches it at the edge. A relative URL
  # keeps the refetch same-origin so it hits that cache instead of reaching the origin directly.
  # @return [String] e.g. "/widgets/whoop"
  def live_update_url
    request.path
  end
end

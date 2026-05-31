module LiveUpdateHelper
  # The URL the embedded markup should refetch itself from on visibilitychange.
  #
  # Intentionally relative (just the request path): the markup is embedded into the static
  # site and re-fetched through a same-origin Netlify proxy that caches it on Netlify's edge.
  # A relative URL keeps the refetch same-origin so it hits that cache instead of reaching the
  # origin directly.
  # @return [String] e.g. "/api/whoop"
  def live_update_url
    request.path
  end
end

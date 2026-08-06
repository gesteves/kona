module LiveUpdateHelper
  # The URL the embedded fragment refetches itself from. Deliberately relative, so the refetch
  # goes through the site's same-origin proxy and hits its edge cache.
  #
  # ⚠️ The fragment's outer element must repeat the web placeholder's attribute cluster but NOT
  # `data-live-update-placeholder-value` — that flag means "I'm an empty skeleton" and makes the
  # element delete itself when a fetch fails, which on real content destroys the rendering on any
  # transient blip. See the cross-app HTML contract in the root CLAUDE.md.
  # @return [String] The request's path.
  def live_update_url
    request.path
  end
end

module LiveUpdateHelper
  # The URL the embedded fragment refetches itself from. Deliberately relative, so the refetch
  # goes through the site's same-origin proxy and hits its edge cache.
  # @return [String] The request's path.
  def live_update_url
    request.path
  end

  # The attribute cluster a fragment's outermost element must carry, mirroring the static site's
  # SiteHelpers#live_update_attrs. Emitting them by hand in each view meant six copies of the same
  # string, and a view that quietly omitted `data-action` would swap in correctly and then simply
  # never refresh again — nothing visible, nothing tested.
  #
  # ⚠️ Deliberately WITHOUT `data-live-update-placeholder-value`. That flag means "I'm an empty
  # skeleton" and makes the element delete itself when a fetch fails; on rendered content it turns
  # a transient blip into lost content. Never add it here. See the cross-app HTML contract in the
  # root CLAUDE.md, and the shared example in spec/support/live_update_contract.rb that pins it.
  # ⚠️ Built as a raw string rather than through `tag.attributes`, which would escape the `->` in
  # the action descriptor to `-&gt;`. Browsers decode that back and Stimulus still works, but the
  # emitted markup would no longer match the placeholder it replaces byte for byte, and this
  # contract is kept in sync by reading the two side by side. The web half
  # (SiteHelpers#live_update_attrs) is built the same way for the same reason.
  #
  # The URL is always this app's own request path, never user input, so it needs no escaping.
  # @return [String] The attributes, marked HTML-safe.
  def live_update_attrs
    %(data-controller="live-update" data-live-update-url-value="#{live_update_url}" data-action="visibilitychange@document->live-update#handleVisibilityChange").html_safe
  end
end

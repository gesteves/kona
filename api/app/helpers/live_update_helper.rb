module LiveUpdateHelper
  # The URL that the fragment in the page gets itself from. It is relative, on purpose, thus the
  # fetch goes through the same-origin proxy of the site and uses its edge cache.
  # @return [String] The path of the request.
  def live_update_url
    request.path
  end

  # The group of attributes that the outermost element of a fragment must have. It is the same as
  # SiteHelpers#live_update_attrs of the static site. With the attributes written by hand in each
  # view, there were six copies of the same string, and a view with no `data-action` would swap in
  # correctly and then never get new content. There would be nothing to see and nothing to test.
  #
  # ⚠️ This does NOT include `data-live-update-placeholder-value`, on purpose. That flag means "I am
  # an empty skeleton" and it makes the element delete itself when a fetch fails. On content that
  # the page shows, it makes a short problem into a loss of content. Never add it here. Refer to the
  # HTML contract between the two apps in the root CLAUDE.md, and to the shared example in
  # spec/support/live_update_contract.rb that tests it.
  # ⚠️ This is a raw string, and not the result of `tag.attributes`. That method would change the
  # `->` in the action descriptor into `-&gt;`. A browser decodes that back and Stimulus still
  # works, but the markup would then not have the same bytes as the placeholder that it replaces,
  # and a person keeps this contract correct with a comparison of the two. The web half
  # (SiteHelpers#live_update_attrs) uses a raw string for the same reason.
  #
  # The URL is always the request path of this app, and never user input, thus it needs no escape.
  # @return [String] The attributes, marked as HTML-safe.
  def live_update_attrs
    %(data-controller="live-update" data-live-update-url-value="#{live_update_url}" data-action="visibilitychange@document->live-update#handleVisibilityChange").html_safe
  end
end

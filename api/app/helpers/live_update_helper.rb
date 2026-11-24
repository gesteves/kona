module LiveUpdateHelper
  # The URL that the fragment in the page gets itself from. It is relative, on purpose, thus the
  # fetch goes through the same-origin proxy of the site and uses its edge cache.
  def live_update_url
    request.path
  end

  # The group of attributes that the outermost element of a fragment must have. It is the same as
  # SiteHelpers#live_update_attrs of the static site. One helper writes them, because a view with
  # no `data-action` swaps in correctly and then never gets new content.
  #
  # ⚠️ This does not include `data-live-update-placeholder-value`, on purpose. That flag means "I am
  # an empty skeleton" and it makes the element delete itself when a fetch fails. On content that
  # the page shows, it makes a short problem into a loss of content. Refer to the HTML contract in
  # the root CLAUDE.md, and to the shared example in spec/support/live_update_contract.rb.
  # ⚠️ This is a raw string, and not the result of `tag.attributes`. That method changes the `->`
  # in the action descriptor into `-&gt;`. Stimulus still works, but the markup then does not have
  # the same bytes as the placeholder that it replaces, and a person compares the two. The web
  # copy uses a raw string for the same reason.
  # @return [String] The attributes, marked as HTML-safe.
  def live_update_attrs
    # The escape changes no byte of a true path. It is here for the case that no controller
    # checks its `:id` first.
    %(data-controller="live-update" data-live-update-url-value="#{ERB::Util.html_escape(live_update_url)}" data-action="visibilitychange@document->live-update#handleVisibilityChange").html_safe
  end
end

# Response headers shared by the owner-facing HTML pages — the admin UI and the sign-in page.
#
# ⚠️ `X-Robots-Tag` rather than relying on the `<meta name="robots">` in layouts/_head.html.erb:
# public/robots.txt already disallows this whole host, so a crawler never fetches the page and
# therefore never sees that tag — while a URL can still be indexed from an external link. The
# header is the signal that survives both, and it covers non-HTML responses too.
module OwnerFacing
  extend ActiveSupport::Concern

  included do
    before_action :set_owner_facing_headers
  end

  private

  # ⚠️ These pages are owner-specific and must never be stored by a browser or the edge. They must
  # also never call `cache_widget` — that policy exists for the public fragments.
  def set_owner_facing_headers
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
  end
end

# Response policy shared by the owner-facing HTML pages — the admin UI, the sign-in page, and the
# Whoop OAuth round-trip. These are the only responses in this app a browser treats as a document,
# and the only ones that carry a session, so they're the only ones that want a CSP.
#
# ⚠️ `X-Robots-Tag` rather than relying on the `<meta name="robots">` in layouts/_head.html.erb:
# public/robots.txt already disallows this whole host, so a crawler never fetches the page and
# therefore never sees that tag — while a URL can still be indexed from an external link. The
# header is the signal that survives both, and it covers non-HTML responses too.
module OwnerFacing
  extend ActiveSupport::Concern

  # Mapbox GL JS is loaded from Mapbox's own CDN by the location picker's Stimulus controller (see
  # app/javascript/controllers/location_map_controller.js), and the map then talks to the tile and
  # telemetry hosts directly. Kept as one list so the policy reads as "us, plus Mapbox".
  MAPBOX_ORIGINS = %w[https://api.mapbox.com https://events.mapbox.com https://*.tiles.mapbox.com].freeze

  included do
    before_action :set_owner_facing_headers

    # ⚠️ Report-Only until CSP_ENFORCE is set, so a missed source degrades to a console report
    # rather than a blank admin page. Flipping it is a fly secret, not a deploy — which is also what
    # makes it revertible while something is actually broken.
    content_security_policy_report_only ENV["CSP_ENFORCE"].blank?

    content_security_policy do |policy|
      policy.default_src :self
      policy.base_uri    :none
      policy.form_action :self
      policy.frame_ancestors :none
      policy.object_src :none

      # `self` covers the fingerprinted admin bundle; the nonce covers the one inline script in
      # layouts/_head.html.erb. ⚠️ No `unsafe-inline` here — the nonce would neutralize it anyway.
      policy.script_src :self, *MAPBOX_ORIGINS

      # ⚠️ `unsafe_inline` is load-bearing: Web Awesome's components and Mapbox GL JS both write
      # styles at runtime. See the nonce_directives note in config/initializers/content_security_policy.rb.
      policy.style_src :self, :unsafe_inline, *MAPBOX_ORIGINS

      policy.img_src     :self, :data, :blob, *MAPBOX_ORIGINS
      policy.font_src    :self, :data
      policy.connect_src :self, *MAPBOX_ORIGINS

      # GL JS runs its renderer in a Worker built from a blob URL.
      policy.worker_src :blob
      policy.child_src  :blob
    end
  end

  private

  # ⚠️ These pages are owner-specific and must never be stored by a browser or the edge. They must
  # also never call `cache_widget` — that policy exists for the public fragments.
  def set_owner_facing_headers
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
  end
end

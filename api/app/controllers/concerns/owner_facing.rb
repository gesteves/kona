# The response policy of the HTML pages for the owner: the admin UI, the sign-in page, and the Whoop
# OAuth round trip. These are the only responses in this app that a browser reads as a document, and
# the only ones with a session. Thus they are the only ones that need a CSP.
#
# ⚠️ This uses `X-Robots-Tag` and does not depend on the `<meta name="robots">` in
# layouts/_head.html.erb. public/robots.txt already refuses this full host, thus a crawler never
# gets the page and never sees that tag. But a search engine can still index a URL from an external
# link. The header works in both conditions, and it also covers a response that is not HTML.
module OwnerFacing
  extend ActiveSupport::Concern

  # The Stimulus controller of the location picker loads Mapbox GL JS from the CDN of Mapbox (refer
  # to app/javascript/controllers/location_map_controller.js), and the map then talks to the tile
  # hosts and the telemetry hosts directly. This is one list, thus the policy reads as "this app,
  # and Mapbox".
  MAPBOX_ORIGINS = %w[https://api.mapbox.com https://events.mapbox.com https://*.tiles.mapbox.com].freeze

  included do
    before_action :set_owner_facing_headers

    # ⚠️ This is Report-Only until CSP_ENFORCE has a value. Thus a source that the policy does not
    # name gives a console report and not a blank admin page. A fly secret changes it, and not a
    # deploy, and that is also what lets you change it back while something is broken.
    content_security_policy_report_only ENV["CSP_ENFORCE"].blank?

    content_security_policy do |policy|
      policy.default_src :self
      policy.base_uri    :none
      policy.form_action :self
      policy.frame_ancestors :none
      policy.object_src :none

      # `self` covers the admin bundle with its fingerprint. The nonce covers the one inline script
      # in layouts/_head.html.erb. ⚠️ Do not add `unsafe-inline` here: the nonce would stop it.
      policy.script_src :self, *MAPBOX_ORIGINS

      # ⚠️ `unsafe_inline` is necessary: the Web Awesome components and Mapbox GL JS both write
      # styles at run time. Refer to the nonce_directives note in
      # config/initializers/content_security_policy.rb.
      policy.style_src :self, :unsafe_inline, *MAPBOX_ORIGINS

      policy.img_src     :self, :data, :blob, *MAPBOX_ORIGINS
      policy.font_src    :self, :data
      policy.connect_src :self, *MAPBOX_ORIGINS

      # GL JS runs its renderer in a Worker that it makes from a blob URL.
      policy.worker_src :blob
      policy.child_src  :blob
    end
  end

  private

  # ⚠️ These pages belong to the owner, thus a browser and the edge must never store them. They must
  # also never call `cache_widget`: that policy is for the public fragments.
  def set_owner_facing_headers
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
  end
end

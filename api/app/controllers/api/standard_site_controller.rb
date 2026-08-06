module Api
  # Serves the standard.site verification data the web build needs. Every per-document at://
  # URI is derived deterministically from the DID on the web side, so this is all it needs.
  # Fetched at build time rather than by browsers, and durably edge-cached since the DID is
  # stable. An empty response makes the build omit the verification markup.
  class StandardSiteController < BaseController
    # Deliberately public: the data is public on the AT Protocol, and this is fetched at build
    # time directly rather than through the token-injecting proxy, so gating it would couple
    # the web build to the shared secret.
    skip_before_action :authenticate_bearer_token!

    def show
      did = StandardSite.new.did
      return render_empty if did.blank?

      cache_widget(ttl: 1.hour)
      render json: {
        did: did,
        publication_uri: StandardSite.publication_uri(did)
      }
    end
  end
end

module Api
  # Serves the standard.site verification data the web build needs: the account DID and
  # the publication URI. Every other URI (per-document at:// URIs) is derived
  # deterministically from the DID on the web side, so this is all the build needs.
  #
  # Fetched at build time (not by browsers), so it's durably edge-cached — the DID is
  # stable. When the Bluesky credentials are absent the DID can't be resolved; an empty
  # response makes the web build omit the verification markup.
  class StandardSiteController < BaseController
    # Intentionally public: the data (DID + publication URI) is public on the AT Protocol, and
    # this is fetched at build time directly via KONA_API_URL (not through the token-injecting
    # proxy), so gating it would couple the web build to the shared secret.
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

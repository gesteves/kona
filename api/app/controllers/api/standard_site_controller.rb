module Api
  # Serves the standard.site verification data the web build needs: the account DID and
  # the publication URI. Every other URI (per-document at:// URIs) is derived
  # deterministically from the DID on the web side, so this is all the build needs.
  #
  # Fetched at build time (not by browsers), so it's durably edge-cached — the DID is
  # stable. When the Bluesky credentials are absent the DID can't be resolved; an empty
  # response makes the web build omit the verification markup.
  class StandardSiteController < BaseController
    def show
      did = StandardSite.new.did
      return render_empty if did.blank?

      cache_widget(ttl: 1.hour)
      render json: {
        did: did,
        publication_uri: "at://#{did}/site.standard.publication/self"
      }
    end
  end
end

module Api
  # Gives the standard.site verification data that the web build needs. The web side makes the at://
  # URI of each document from the DID, and it always gets the same result. Thus this data is
  # sufficient. The build gets it, and a browser does not, and the edge keeps it for a long time
  # because the DID does not change. An empty response makes the build omit the verification
  # markup.
  class StandardSiteController < BaseController
    # This is public, on purpose: the data is public on the AT Protocol, and the build gets it
    # directly and not through the proxy that adds the token. Thus a check here would make the web
    # build depend on the shared secret.
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

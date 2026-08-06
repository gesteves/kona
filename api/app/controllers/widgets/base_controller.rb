module Widgets
  # Base controller for the /widgets/* endpoints: bare HTML fragments embedded into the static
  # site. Every one requires the API_TOKEN bearer, which the web app's proxy injects, so the
  # origin stays closed to the public and scanners get a cheap 401 before any work.
  class BaseController < TokenGatedController
    include UpstreamIsolation

    # The shape of a Contentful entry id. Anything else in an `:id` segment can never match a
    # real entry, and /widgets/* is exempt from origin rate limiting, so an unvalidated path id
    # is the one remaining cache-buster surface — keep this check in front of per-id work.
    CONTENTFUL_ID_FORMAT = /\A[A-Za-z0-9_-]{1,64}\z/

    private

    # @return [String, nil] The `:id` param when it looks like a Contentful entry id, else nil.
    def contentful_id_param
      id = params[:id].to_s
      id if id.match?(CONTENTFUL_ID_FORMAT)
    end
  end
end

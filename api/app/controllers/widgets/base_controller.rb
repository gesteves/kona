module Widgets
  # Base controller for the /widgets/* endpoints: the HTML fragments embedded into the static
  # site via its live-update Stimulus controller. Inherits ActionController::Base directly
  # (not ApplicationController) to skip the modern-browser gate, since these are endpoints
  # fetched programmatically. Renders bare fragments with no layout.
  #
  # All widget endpoints require the API_TOKEN bearer token, injected by the web app's proxy
  # (web/src/api-proxy.ts) — they are not meant to be hit directly.
  # This keeps the widget origin closed to the public so scanners/abusers get a cheap 401
  # before any controller or upstream-API work.
  class BaseController < TokenGatedController
    include UpstreamIsolation

    # Shape of a Contentful entry id (URL-safe alphanumerics). Anything else in an `:id` path
    # segment is garbage — it can never match a real entry, so the id-parameterized widgets
    # reject it here, before any lookup work, rather than acting on it. /widgets/* is exempt
    # from origin rate limiting (all legitimate traffic shares the web proxy's egress IPs), so
    # unvalidated path ids are the one remaining cache-buster surface — keep this check in
    # front of anything that would do per-id work.
    CONTENTFUL_ID_FORMAT = /\A[A-Za-z0-9_-]{1,64}\z/

    private

    # @return [String, nil] The `:id` param when it looks like a Contentful entry id, else nil.
    def contentful_id_param
      id = params[:id].to_s
      id if id.match?(CONTENTFUL_ID_FORMAT)
    end
  end
end

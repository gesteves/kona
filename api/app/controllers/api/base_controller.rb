module Api
  # Base controller for the /api/* widget endpoints. Inherits ActionController::Base directly
  # (not ApplicationController) to skip the modern-browser gate, since these are endpoints
  # fetched programmatically. Renders bare fragments with no layout.
  #
  # All endpoints require the API_TOKEN bearer token, injected by the web app's Netlify proxy
  # (web/netlify/functions/api-proxy.mts) — they are not meant to be hit directly. This keeps
  # the widget origin closed to the public so scanners/abusers get a cheap 401 before any
  # controller or upstream-API work. Endpoints with their own auth scheme (the HMAC-verified
  # Contentful webhook) or that are intentionally public (standard-site, build-time fetched)
  # skip_before_action this check.
  class BaseController < ActionController::Base
    include LiveWidget
    include TokenAuthentication

    layout false

    before_action :authenticate_bearer_token!
  end
end

module Widgets
  # Base controller for the /widgets/* endpoints: the HTML fragments embedded into the static
  # site via its live-update Stimulus controller. Inherits ActionController::Base directly
  # (not ApplicationController) to skip the modern-browser gate, since these are endpoints
  # fetched programmatically. Renders bare fragments with no layout.
  #
  # All widget endpoints require the API_TOKEN bearer token, injected by the web app's Netlify
  # proxy (web/netlify/functions/widget-proxy.mts) — they are not meant to be hit directly.
  # This keeps the widget origin closed to the public so scanners/abusers get a cheap 401
  # before any controller or upstream-API work.
  class BaseController < ActionController::Base
    include LiveWidget
    include TokenAuthentication
    include UpstreamIsolation

    layout false

    before_action :authenticate_bearer_token!
  end
end

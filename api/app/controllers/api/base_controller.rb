module Api
  # Base controller for the /api/* structured-data endpoints — the ones that accept or return
  # data (JSON, writes) rather than widget markup (those live under Widgets::BaseController).
  # Inherits ActionController::Base directly (not ApplicationController) to skip the
  # modern-browser gate, since these are endpoints fetched programmatically.
  #
  # Endpoints require the API_TOKEN bearer token by default (e.g. POST /api/location) so
  # scanners/abusers get a cheap 401 before any controller work. Intentionally public
  # endpoints (standard-site, build-time fetched) skip_before_action this check.
  class BaseController < ActionController::Base
    include LiveWidget
    include TokenAuthentication

    layout false

    before_action :authenticate_bearer_token!
  end
end

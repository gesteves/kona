# Abstract base for the token-gated programmatic endpoints (Widgets::BaseController and
# Api::BaseController). Inherits ActionController::Base directly (not ApplicationController)
# to skip the modern-browser gate, since these endpoints are fetched programmatically, and
# renders bare responses with no layout.
#
# Every action requires the API_TOKEN bearer (TokenAuthentication) so scanners/abusers get a
# cheap 401 before any controller or upstream-API work; intentionally public endpoints
# skip_before_action the check.
class TokenGatedController < ActionController::Base
  include LiveWidget
  include TokenAuthentication

  layout false

  before_action :authenticate_bearer_token!
end

# The abstract base of the endpoints for a machine, which need a token. It inherits from
# ActionController::Base directly, thus it does not use the modern-browser check, and it renders a
# plain response with no layout.
#
# Each action needs the API_TOKEN bearer token, thus a scanner gets a fast 401 before each controller
# operation and each upstream call. An endpoint that is public, on purpose, removes that check with
# skip_before_action.
class TokenGatedController < ActionController::Base
  include LiveWidget
  include TokenAuthentication

  layout false

  before_action :authenticate_bearer_token!
end

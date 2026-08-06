# Abstract base for the token-gated programmatic endpoints. Inherits ActionController::Base
# directly to skip the modern-browser gate, and renders bare responses with no layout.
#
# Every action requires the API_TOKEN bearer, so scanners get a cheap 401 before any controller
# or upstream work; deliberately public endpoints skip_before_action the check.
class TokenGatedController < ActionController::Base
  include LiveWidget
  include TokenAuthentication

  layout false

  before_action :authenticate_bearer_token!
end

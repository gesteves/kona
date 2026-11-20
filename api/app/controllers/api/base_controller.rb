module Api
  # The base controller of the /api/* structured-data endpoints. They take or give data, and not the
  # widget markup of Widgets::BaseController. They need a bearer token by default. An endpoint that
  # is public, on purpose, removes that check with skip_before_action.
  class BaseController < TokenGatedController
    # ⚠️ No endpoint here has a session. The bearer token authenticates a request, or the endpoint
    # is public on purpose, thus the forgery check protects nothing and would refuse each POST
    # with a 422.
    skip_forgery_protection
  end
end

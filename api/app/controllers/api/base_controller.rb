module Api
  # The base controller of the /api/* structured-data endpoints. They take or give data, and not the
  # widget markup of Widgets::BaseController. They need a bearer token by default. An endpoint that
  # is public, on purpose, removes that check with skip_before_action.
  class BaseController < TokenGatedController
  end
end

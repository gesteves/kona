module Webhooks
  # The base controller of the /webhooks/* endpoints, with one controller for each sending service.
  # It inherits from ActionController::Base directly, thus it does not use the modern-browser check,
  # because a machine sends each of these requests.
  #
  # There is no API_TOKEN bearer token: a sender cannot have our token, thus each controller uses the
  # method of its own service. The forgery protection is off for the same reason.
  class BaseController < ActionController::Base
    layout false

    skip_forgery_protection
  end
end

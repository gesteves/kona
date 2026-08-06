module Webhooks
  # Base controller for the /webhooks/* endpoints, one per sending service. Inherits
  # ActionController::Base directly to skip the modern-browser gate, since these are hit by
  # machines.
  #
  # No API_TOKEN bearer: senders can't carry our token, so each controller authenticates with
  # its own service's scheme. Forgery protection is skipped for the same reason.
  class BaseController < ActionController::Base
    layout false

    skip_forgery_protection
  end
end

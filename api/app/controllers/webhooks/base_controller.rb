module Webhooks
  # Base controller for the /webhooks/* endpoints: inbound webhooks from external services,
  # one controller per service. Inherits ActionController::Base directly (not
  # ApplicationController) to skip the modern-browser gate — these are hit by machines.
  #
  # No API_TOKEN bearer here: webhook senders can't carry our token, so each service's
  # controller authenticates with that service's own scheme (e.g. Contentful's HMAC request
  # verification). Forgery protection is skipped for the same reason — these are
  # cross-origin POSTs with no session.
  class BaseController < ActionController::Base
    layout false

    skip_forgery_protection
  end
end

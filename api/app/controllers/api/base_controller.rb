module Api
  # Base controller for the public /api/* widget endpoints. Inherits ActionController::Base
  # directly (not ApplicationController) to skip the modern-browser gate, since these are
  # public, cross-origin endpoints fetched programmatically. Renders bare fragments with no
  # layout.
  class BaseController < ActionController::Base
    include LiveWidget

    layout false
  end
end

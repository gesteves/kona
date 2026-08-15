module Admin
  # Base controller for the owner-facing admin UI — the one part of this app that renders full
  # HTML pages rather than widget fragments. Inherits ActionController::Base directly, like every
  # other controller here, to skip the modern-browser gate.
  class BaseController < ActionController::Base
    include Authentication
    include OwnerFacing

    layout "admin"

    before_action :require_owner!
  end
end

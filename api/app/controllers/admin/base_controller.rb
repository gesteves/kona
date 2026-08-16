module Admin
  # Base controller for the owner-facing admin UI — the one part of this app that renders full
  # HTML pages rather than widget fragments. Inherits ActionController::Base directly, like every
  # other controller here, to skip the modern-browser gate.
  class BaseController < ActionController::Base
    include Authentication
    include OwnerFacing

    layout "admin"

    before_action :require_owner!
    before_action :load_quarantine_count

    private

    # How many messages are waiting in the spam quarantine, for the nav's badge.
    #
    # Loaded here rather than in ContactController because the nav is on every admin page. It's a
    # single HLEN, and these pages already make several Redis round-trips apiece for their icons.
    def load_quarantine_count
      @quarantine_count = SpamQuarantine.new.count
    end
  end
end

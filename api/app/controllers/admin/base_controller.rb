module Admin
  # The base controller of the admin UI of the owner. That UI is the one part of this app that renders
  # full HTML pages and not widget fragments. It inherits from ActionController::Base directly, as
  # each other controller here does, thus it does not use the modern-browser check.
  class BaseController < ActionController::Base
    include Authentication
    include OwnerFacing

    layout "admin"

    before_action :require_owner!
    # ⚠️ HTML only. A JSON action and an image action render no layout, and the status poll of the
    # Course maps page and the previews of the Social media page call those many times.
    before_action :load_quarantine_count, if: -> { request.format.html? }

    private

    # The number of messages in the spam quarantine, for the badge in the nav.
    #
    # This code is here and not in SpamController, because the nav is on each admin page. It is one
    # HLEN, and each of these pages already makes more than one Redis request for its icons.
    def load_quarantine_count
      @quarantine_count = SpamQuarantine.new.count
    end
  end
end

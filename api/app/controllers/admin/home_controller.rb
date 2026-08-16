module Admin
  # The admin landing page. Deliberately thin for now — it exists so the shell has a home and the
  # sign-in redirect has somewhere to land.
  #
  # ⚠️ Named for the page, but it must stay mounted at `/`, never at `/home`. The zone's
  # scanner-noise rule blocks the `/home/` prefix family across every host, so drawing this
  # controller at its own name would 403 it in production and nowhere else.
  class HomeController < BaseController
    # GET /
    def show
    end
  end
end

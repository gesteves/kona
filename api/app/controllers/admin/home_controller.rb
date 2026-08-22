module Admin
  # The first page of the admin. It is small for now: it exists to give the shell a home page and to
  # give the sign-in redirect a destination.
  #
  # ⚠️ The name says the page, but Rails must draw it at `/`, and never at `/home`. The scanner-noise
  # rule of the zone blocks the `/home/` prefix family on each host. Thus a route at the name of this
  # controller would give a 403 in production, and nowhere else.
  class HomeController < BaseController
    # GET /
    def show
    end
  end
end

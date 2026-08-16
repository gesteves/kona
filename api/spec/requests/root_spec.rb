require "rails_helper"

# `/` is answered by two different routes depending on the host, and which one wins is decided by
# the `API_HOST` constraint in config/routes.rb plus the order they're drawn in:
#
#   * admin host (or any host when API_HOST is unset) — the admin home page, owner-gated
#   * public API host — a 301 to the main site, since that host has no UI
#
# spec/requests/host_constraints_spec.rb covers the split with API_HOST set; this file covers the
# unset case, which is dev, CI, and the .fly.dev origin.
RSpec.describe "Root", type: :request do
  describe "GET / with API_HOST unset" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SITE_URL").and_return("https://www.example.test")
      allow(ENV).to receive(:[]).with("API_HOST").and_return(nil)
    end

    it "serves the admin home page, sending a signed-out visitor to sign in" do
      get "/"

      expect(response).to redirect_to("/signin")
    end

    it "serves the home page itself once signed in" do
      allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return("owner@example.com")
      allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
      sign_in_as(email: "owner@example.com")

      get "/"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<wa-page")
    end
  end

  describe "GET / on the public API host" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SITE_URL").and_return("https://www.example.test")
      allow(ENV).to receive(:[]).with("API_HOST").and_return("api.example.test")
    end

    it "permanently redirects to the main site (host from SITE_URL)" do
      get "http://api.example.test/"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://www.example.test/")
    end
  end
end

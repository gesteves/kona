require "rails_helper"

# Two different routes answer `/`, and the host decides which one. The `API_HOST` constraint in
# config/routes.rb, and the order that Rails draws the two routes in, make that decision:
#
#   * the admin host, and each host when API_HOST has no value: the admin home page, which the owner
#     session controls.
#   * the public API host: a 301 to the main site, because that host has no UI.
#
# spec/requests/host_constraints_spec.rb covers the two routes with a value in API_HOST. This file
# covers the condition with no value, which is development, CI, and the .fly.dev origin.
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

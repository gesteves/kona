require "rails_helper"

RSpec.describe "Root", type: :request do
  describe "GET /" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SITE_URL").and_return("https://www.example.test")
    end

    it "permanently redirects to the main site (host from SITE_URL)" do
      get "/"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://www.example.test/")
    end
  end
end

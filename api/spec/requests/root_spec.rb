require "rails_helper"

RSpec.describe "Root", type: :request do
  describe "GET /" do
    it "permanently redirects to the main site" do
      get "/"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://www.giventotri.com/")
    end
  end
end

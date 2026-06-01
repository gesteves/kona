require "rails_helper"

RSpec.describe "Api::StandardSite", type: :request do
  context "when the DID resolves" do
    before { allow_any_instance_of(StandardSite).to receive(:did).and_return("did:plc:abc") }

    it "returns the DID and derived publication URI" do
      get "/api/standard-site"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["did"]).to eq("did:plc:abc")
      expect(json["publication_uri"]).to eq("at://did:plc:abc/site.standard.publication/self")
    end

    it "sets a durable one-hour edge cache" do
      get "/api/standard-site"

      edge = response.headers["Netlify-CDN-Cache-Control"]
      expect(edge).to include("durable")
      expect(edge).to include("max-age=3600")
    end
  end

  context "when the DID is unavailable (no credentials)" do
    before { allow_any_instance_of(StandardSite).to receive(:did).and_return(nil) }

    it "returns an empty body so the web build omits the verification markup" do
      get "/api/standard-site"

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("")
      expect(response.headers["Netlify-CDN-Cache-Control"]).not_to include("durable")
    end
  end
end

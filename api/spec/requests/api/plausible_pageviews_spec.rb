require "rails_helper"

RSpec.describe "Api::Plausible pageviews", type: :request do
  let(:article) { DeepOstruct.wrap(slug: "my-race-report", published: "2026-05-01T09:00:00-06:00", sys: { id: "abc123", first_published_at: "2026-05-01T09:00:00Z" }) }

  before do
    allow_any_instance_of(Articles).to receive(:find).and_return(article)
    allow_any_instance_of(Plausible).to receive(:query).and_return(results: [{ metrics: [1234], dimensions: [] }])
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  it "renders the view-count span (icon + linked count)" do
    get "/api/plausible/pageviews/abc123", headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("<span")
    expect(response.body).to include("<svg")                       # eye icon, rendered unescaped
    expect(response.body).to include("Viewed 1,234 times")
    expect(response.body).to include('href="https://plausible.io/')
    # Reconstructed path in the dashboard link, URL-encoded into the query string.
    expect(response.body).to include(ERB::Util.url_encode("/2026/05/01/my-race-report/"))
  end

  it "URL-encodes a slug with special characters in the dashboard link" do
    weird = DeepOstruct.wrap(slug: "q&a-recap", published: "2026-05-01T09:00:00-06:00", sys: { id: "abc123", first_published_at: "2026-05-01T09:00:00Z" })
    allow_any_instance_of(Articles).to receive(:find).and_return(weird)

    get "/api/plausible/pageviews/abc123", headers: auth_headers

    # The raw "&" must not leak into the query string (it would inject a bogus param).
    expect(response.body).to include(ERB::Util.url_encode("/2026/05/01/q&a-recap/"))
    expect(response.body).not_to include("page,/2026/05/01/q&a-recap/")
  end

  it "queries Plausible for the reconstructed article path" do
    expect_any_instance_of(Plausible).to receive(:query)
      .with(hash_including(filters: [["is", "event:page", ["/2026/05/01/my-race-report/"]]]))
      .and_return(results: [{ metrics: [5] }])

    get "/api/plausible/pageviews/abc123", headers: auth_headers
    expect(response.body).to include("Viewed 5 times")
  end

  it "renders 'Never viewed' for zero pageviews" do
    allow_any_instance_of(Plausible).to receive(:query).and_return(results: [{ metrics: [0] }])

    get "/api/plausible/pageviews/abc123", headers: auth_headers
    expect(response.body).to include("Never viewed")
  end

  it "sets a one-hour caching header" do
    get "/api/plausible/pageviews/abc123", headers: auth_headers

    cache_control = response.headers["Cache-Control"]
    expect(cache_control).to include("public")
    expect(cache_control).to include("max-age=0")
    expect(cache_control).to include("stale-while-revalidate=3600")

    edge = response.headers["Netlify-CDN-Cache-Control"]
    expect(edge).to include("durable")
    expect(edge).to include("max-age=3600")
    expect(edge).to include("stale-while-revalidate=86400")
    expect(edge).to include("stale-if-error=86400")
  end

  context "when the article is not found" do
    before { allow_any_instance_of(Articles).to receive(:find).and_return(nil) }

    it "returns an empty body" do
      get "/api/plausible/pageviews/nope", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("")
    end
  end

  context "when Plausible is unavailable" do
    before { allow_any_instance_of(Plausible).to receive(:query).and_return(nil) }

    it "returns an empty body so the live-update controller collapses the placeholder" do
      get "/api/plausible/pageviews/abc123", headers: auth_headers
      expect(response.body).to eq("")
    end
  end

  context "when the article has no publish date" do
    before do
      undated = DeepOstruct.wrap(slug: "draft", published: nil, sys: { id: "abc123", first_published_at: nil })
      allow_any_instance_of(Articles).to receive(:find).and_return(undated)
    end

    it "returns an empty body without querying Plausible" do
      expect_any_instance_of(Plausible).not_to receive(:query)

      get "/api/plausible/pageviews/abc123", headers: auth_headers
      expect(response.body).to eq("")
    end
  end

  context "when PLAUSIBLE_SITE_ID is unset" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PLAUSIBLE_SITE_ID").and_return(nil)
    end

    it "returns an empty body without querying Plausible" do
      expect_any_instance_of(Plausible).not_to receive(:query)

      get "/api/plausible/pageviews/abc123", headers: auth_headers
      expect(response.body).to eq("")
    end
  end

  it "requires the API_TOKEN bearer (the proxy injects it; direct hits are rejected)" do
    get "/api/plausible/pageviews/abc123"
    expect(response).to have_http_status(:unauthorized)

    get "/api/plausible/pageviews/abc123", headers: { "Authorization" => "Bearer wrong" }
    expect(response).to have_http_status(:unauthorized)
  end
end

require "rails_helper"

RSpec.describe "Api::Plausible pageviews", type: :request do
  let(:article) { DeepOstruct.wrap(slug: "my-race-report", published: "2026-05-01T09:00:00-06:00", sys: { id: "abc123", first_published_at: "2026-05-01T09:00:00Z" }) }

  before do
    allow_any_instance_of(Articles).to receive(:find).and_return(article)
    allow_any_instance_of(Plausible).to receive(:query).and_return(results: [{ metrics: [1234], dimensions: [] }])
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  it "renders the view-count span (icon + linked count)" do
    get "/api/plausible/pageviews/abc123"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("<span")
    expect(response.body).to include("<svg")                       # eye icon, rendered unescaped
    expect(response.body).to include("Viewed 1,234 times")
    expect(response.body).to include('href="https://plausible.io/')
    expect(response.body).to include("/2026/05/01/my-race-report/") # reconstructed path in the dashboard link
  end

  it "queries Plausible for the reconstructed article path" do
    expect_any_instance_of(Plausible).to receive(:query)
      .with(hash_including(filters: [["is", "event:page", ["/2026/05/01/my-race-report/"]]]))
      .and_return(results: [{ metrics: [5] }])

    get "/api/plausible/pageviews/abc123"
    expect(response.body).to include("Viewed 5 times")
  end

  it "renders 'Never viewed' for zero pageviews" do
    allow_any_instance_of(Plausible).to receive(:query).and_return(results: [{ metrics: [0] }])

    get "/api/plausible/pageviews/abc123"
    expect(response.body).to include("Never viewed")
  end

  it "sets a one-hour caching header" do
    get "/api/plausible/pageviews/abc123"

    cache_control = response.headers["Cache-Control"]
    expect(cache_control).to include("public")
    expect(cache_control).to include("max-age=3600")
  end

  context "when the article is not found" do
    before { allow_any_instance_of(Articles).to receive(:find).and_return(nil) }

    it "returns an empty body" do
      get "/api/plausible/pageviews/nope"
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("")
    end
  end

  context "when Plausible is unavailable" do
    before { allow_any_instance_of(Plausible).to receive(:query).and_return(nil) }

    it "returns an empty body so the placeholder stays" do
      get "/api/plausible/pageviews/abc123"
      expect(response.body).to eq("")
    end
  end
end

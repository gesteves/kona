require "rails_helper"

RSpec.describe "Widgets::Plausible pageviews", type: :request do
  let(:article) { DeepOstruct.wrap(slug: "my-race-report", published: "2026-05-01T09:00:00-06:00", sys: { id: "abc123", first_published_at: "2026-05-01T09:00:00Z" }) }

  before do
    # The widget is empty with no site id. This stub gives one, thus the spec does not depend on the
    # local .env of a person. That var has no value in CI.
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("PLAUSIBLE_SITE_ID").and_return("example.com")

    allow_any_instance_of(Articles).to receive(:find).and_return(article)
    allow_any_instance_of(Plausible).to receive(:pageviews_by_path).and_return("/2026/05/01/my-race-report/" => 1234)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  it_behaves_like "a live-update fragment", "/widgets/plausible/pageviews/abc123"

  it "renders the view-count span (icon + linked count)" do
    get "/widgets/plausible/pageviews/abc123", headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("<span")
    expect(response.body).to include("<svg")                       # eye icon, rendered unescaped
    expect(response.body).to include("Viewed 1,234 times")
    expect(response.body).to include('href="https://plausible.io/')
    # The path in the dashboard link, in a URL-safe form in the query string.
    expect(response.body).to include(ERB::Util.url_encode("/2026/05/01/my-race-report/"))
  end

  it "carries the live-update wiring so the count keeps refreshing after the first swap" do
    get "/widgets/plausible/pageviews/abc123", headers: auth_headers

    expect(response.body).to include('data-controller="live-update"')
    expect(response.body).to include('data-live-update-url-value="/widgets/plausible/pageviews/abc123"')
    expect(response.body).to include('data-action="visibilitychange@document->live-update#handleVisibilityChange"')
  end

  it "URL-encodes a slug with special characters in the dashboard link" do
    weird = DeepOstruct.wrap(slug: "q&a-recap", published: "2026-05-01T09:00:00-06:00", sys: { id: "abc123", first_published_at: "2026-05-01T09:00:00Z" })
    allow_any_instance_of(Articles).to receive(:find).and_return(weird)

    get "/widgets/plausible/pageviews/abc123", headers: auth_headers

    # A plain "&" must not go into the query string, because it would add an incorrect
    # parameter.
    expect(response.body).to include(ERB::Util.url_encode("/2026/05/01/q&a-recap/"))
    expect(response.body).not_to include("page,/2026/05/01/q&a-recap/")
  end

  it "looks the count up by the reconstructed article path" do
    allow_any_instance_of(Plausible).to receive(:pageviews_by_path)
      .and_return("/2026/05/01/my-race-report/" => 5, "/2026/05/01/some-other-post/" => 900)

    get "/widgets/plausible/pageviews/abc123", headers: auth_headers
    expect(response.body).to include("Viewed 5 times")
  end

  # One query for the full site gives the data of each article. A query for each article would
  # multiply the number of calls by the number of articles, and it would go past the limit of
  # Plausible of 600 calls each hour, at this TTL.
  it "asks for every article's counts in one all-time query, not one query per article" do
    expect_any_instance_of(Plausible).to receive(:pageviews_by_path)
      .with(date_range: "all").once.and_return("/2026/05/01/my-race-report/" => 5)

    get "/widgets/plausible/pageviews/abc123", headers: auth_headers
    expect(response.body).to include("Viewed 5 times")
  end

  it "renders 'Never viewed' for an article absent from the results" do
    allow_any_instance_of(Plausible).to receive(:pageviews_by_path).and_return("/2026/05/01/another-post/" => 900)

    get "/widgets/plausible/pageviews/abc123", headers: auth_headers
    expect(response.body).to include("Never viewed")
  end

  it "renders 'Never viewed' for zero pageviews" do
    allow_any_instance_of(Plausible).to receive(:pageviews_by_path).and_return("/2026/05/01/my-race-report/" => 0)

    get "/widgets/plausible/pageviews/abc123", headers: auth_headers
    expect(response.body).to include("Never viewed")
  end

  it "sets a five-minute caching header" do
    get "/widgets/plausible/pageviews/abc123", headers: auth_headers

    cache_control = response.headers["Cache-Control"]
    expect(cache_control).to include("public")
    expect(cache_control).to include("max-age=0")
    expect(cache_control).to include("stale-while-revalidate=300")

    edge = response.headers["CDN-Cache-Control"]
    expect(edge).to include("public")
    expect(edge).to include("max-age=300")
    expect(edge).to include("stale-while-revalidate=3600")
    expect(edge).to include("stale-if-error=86400")
  end

  context "when the id is not a valid Contentful entry id" do
    it "returns an empty body without doing any lookup work" do
      expect_any_instance_of(Articles).not_to receive(:find)
      expect_any_instance_of(Plausible).not_to receive(:pageviews_by_path)

      get "/widgets/plausible/pageviews/#{"a" * 65}", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("")
    end
  end

  context "when the article is not found" do
    before { allow_any_instance_of(Articles).to receive(:find).and_return(nil) }

    it "returns an empty body" do
      get "/widgets/plausible/pageviews/nope", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("")
    end
  end

  context "when Plausible is unavailable" do
    before { allow_any_instance_of(Plausible).to receive(:pageviews_by_path).and_return(nil) }

    it "returns an empty body so the live-update controller collapses the placeholder" do
      get "/widgets/plausible/pageviews/abc123", headers: auth_headers
      expect(response.body).to eq("")
    end
  end

  context "when the article has no publish date" do
    before do
      undated = DeepOstruct.wrap(slug: "draft", published: nil, sys: { id: "abc123", first_published_at: nil })
      allow_any_instance_of(Articles).to receive(:find).and_return(undated)
    end

    it "returns an empty body without querying Plausible" do
      expect_any_instance_of(Plausible).not_to receive(:pageviews_by_path)

      get "/widgets/plausible/pageviews/abc123", headers: auth_headers
      expect(response.body).to eq("")
    end
  end

  context "when PLAUSIBLE_SITE_ID is unset" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PLAUSIBLE_SITE_ID").and_return(nil)
    end

    it "returns an empty body without querying Plausible" do
      expect_any_instance_of(Plausible).not_to receive(:pageviews_by_path)

      get "/widgets/plausible/pageviews/abc123", headers: auth_headers
      expect(response.body).to eq("")
    end
  end

  it "requires the API_TOKEN bearer (the proxy injects it; direct hits are rejected)" do
    get "/widgets/plausible/pageviews/abc123"
    expect(response).to have_http_status(:unauthorized)

    get "/widgets/plausible/pageviews/abc123", headers: { "Authorization" => "Bearer wrong" }
    expect(response).to have_http_status(:unauthorized)
  end
end

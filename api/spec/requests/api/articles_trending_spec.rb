require "rails_helper"

RSpec.describe "Api::Articles trending", type: :request do
  # Builds a decorated article the way Articles#list would return it.
  def article(id:, title:, slug:, published_at:, summary: "A short summary.", entry_type: "Article", draft: false)
    path = "/#{DateTime.parse(published_at).strftime('%Y/%m/%d')}/#{slug}/"
    DeepOstruct.wrap(
      title: title, slug: slug, summary: summary, published_at: published_at,
      entry_type: entry_type, draft: draft, path: path, sys: { id: id }
    )
  end

  let(:art_newest)   { article(id: "a1", title: "Newest Article",   slug: "newest",   published_at: "2024-12-30T10:00:00Z") }
  let(:art_april)    { article(id: "a2", title: "April Article",    slug: "april",    published_at: "2024-04-01T10:00:00Z") }
  let(:art_march)    { article(id: "a3", title: "March Article",    slug: "march",    published_at: "2024-03-01T10:00:00Z") }
  let(:art_february) { article(id: "a4", title: "February Article", slug: "february", published_at: "2024-02-01T10:00:00Z") }
  let(:art_spiking)  { article(id: "a5", title: "Spiking Article",  slug: "spiking",  published_at: "2024-01-01T10:00:00Z") }
  let(:art_steady)   { article(id: "a6", title: "Steady Article",   slug: "steady",   published_at: "2023-12-01T10:00:00Z") }
  let(:art_short)    { article(id: "s1", title: "A Short Post",     slug: "short",     published_at: "2024-06-01T10:00:00Z", entry_type: "Short") }

  let(:corpus) { [art_newest, art_april, art_march, art_february, art_spiking, art_steady, art_short] }

  # a5 surges (a modest recent count on a tiny baseline); a6 is steadily popular (high traffic in line
  # with its own high baseline); everyone else has no traffic. So ranking is: a5, a6, then the rest by
  # recency.
  def rows(by_path)
    by_path.map { |path, total| { dimensions: [path], metrics: [total] } }
  end

  before do
    allow_any_instance_of(Articles).to receive(:list).and_return(corpus)
    recent = rows(art_spiking.path => 15, art_steady.path => 72)
    baseline = rows(art_spiking.path => 30, art_steady.path => 2000)
    # The recent window and the baseline are two event:page queries over different ranges; branch on
    # the range span (recent is short, baseline is ~a month) to answer each.
    allow_any_instance_of(Plausible).to receive(:query) do |**kwargs|
      first, last = kwargs[:date_range]
      span_hours = (Time.parse(last) - Time.parse(first)) / 3600.0
      { results: span_hours <= (TrendingArticles::RECENT_WINDOW_HOURS + 1) ? recent : baseline }
    end
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    # The ranking is cached via cached_json; stub Redis so the suite stays Redis-free and examples
    # don't leak cached results into each other.
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  describe "GET /api/articles/trending (all)" do
    it "renders the trending-articles section as a live-update fragment" do
      get "/api/articles/trending", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('class="collection collection--halves"')
      expect(response.body).to include("Trending Articles")
      expect(response.body).to include('data-controller="live-update"')
      expect(response.body).to include('data-live-update-url-value="/api/articles/trending"')
    end

    it "includes recent articles, excludes Shorts, and orders the rest by trending score" do
      get "/api/articles/trending", headers: auth_headers

      expect(response.body).to include("Spiking Article")
      expect(response.body).to include("Steady Article")
      expect(response.body).to include("Newest Article") # recent articles are NOT excluded here
      expect(response.body).not_to include("A Short Post") # Shorts are excluded
      expect(response.body.index("Spiking Article")).to be < response.body.index("Steady Article")
    end

    it "links each card to the article's computed path" do
      get "/api/articles/trending", headers: auth_headers

      expect(response.body).to include('href="/2024/01/01/spiking/"')
    end

    it "sets a one-hour durable caching header" do
      get "/api/articles/trending", headers: auth_headers

      cache_control = response.headers["Cache-Control"]
      expect(cache_control).to include("public")
      expect(cache_control).to include("max-age=0")
      expect(cache_control).to include("stale-while-revalidate=3600")

      edge = response.headers["Netlify-CDN-Cache-Control"]
      expect(edge).to include("durable")
      expect(edge).to include("max-age=3600")
      expect(edge).to include("stale-while-revalidate=86400")
    end

    context "when there are no articles" do
      before { allow_any_instance_of(Articles).to receive(:list).and_return([]) }

      it "returns an empty body so the placeholder collapses" do
        get "/api/articles/trending", headers: auth_headers

        expect(response).to have_http_status(:ok)
        expect(response.body.strip).to be_empty
      end
    end

    it "requires the API_TOKEN bearer (the proxy injects it; direct hits are rejected)" do
      get "/api/articles/trending"
      expect(response).to have_http_status(:unauthorized)

      get "/api/articles/trending", headers: { "Authorization" => "Bearer wrong" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/articles/trending/:id" do
    it "drops the given article and advertises the path as its refetch URL" do
      get "/api/articles/trending/a5", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Spiking Article") # a5 is excluded
      expect(response.body).to include("Steady Article")       # a non-excluded article still trends
      expect(response.body).to include("Newest Article")
      expect(response.body).to include('data-live-update-url-value="/api/articles/trending/a5"')
    end

    it "ignores a malformed id (serves full trending) and never errors" do
      get "/api/articles/trending/@@@", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Spiking Article") # nothing excluded
      expect(response.body).to include("Steady Article")
    end

    it "requires the API_TOKEN bearer" do
      get "/api/articles/trending/a5"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end

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

  # The spiking article has a low baseline with a big recent surge; the steady one has flat,
  # moderate traffic; everyone else has none. So ranking is: spiking, steady, then the rest by recency.
  def days_back(count)
    (0...count).map { |i| Date.current - i }
  end

  def spike_series(base:, spike:, days: TrendingArticles::WINDOW_DAYS)
    days_back(days).each_with_index.to_h { |day, i| [day, i < TrendingArticles::RECENT_DAYS ? spike : base] }
  end

  def flat_series(rate:, days: TrendingArticles::WINDOW_DAYS)
    days_back(days).to_h { |day| [day, rate] }
  end

  before do
    allow_any_instance_of(Articles).to receive(:list).and_return(corpus)
    allow_any_instance_of(Plausible).to receive(:query) do
      series = {
        art_spiking.path => spike_series(base: 2, spike: 40),
        art_steady.path  => flat_series(rate: 5)
      }
      rows = series.flat_map do |path, by_day|
        by_day.map { |day, pv| { dimensions: [path, day.iso8601], metrics: [pv] } }
      end
      { results: rows }
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
      expect(edge).to include("stale-while-revalidate=3600")
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

  describe "GET /api/articles/trending/exclude/:ids" do
    it "drops the listed articles and advertises the exclude path as its refetch URL" do
      get "/api/articles/trending/exclude/a5,a6", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Spiking Article")
      expect(response.body).not_to include("Steady Article")
      expect(response.body).to include("Newest Article") # a non-excluded article still trends
      expect(response.body).to include('data-live-update-url-value="/api/articles/trending/exclude/a5,a6"')
    end

    it "sanitizes the id list: honors valid ids, ignores garbage, and never errors" do
      get "/api/articles/trending/exclude/a5,@@@,#{'x' * 100}", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Spiking Article") # a5 is honored
      expect(response.body).to include("Steady Article")       # garbage (@@@, over-long) is dropped
    end

    it "requires the API_TOKEN bearer" do
      get "/api/articles/trending/exclude/a5,a6"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end

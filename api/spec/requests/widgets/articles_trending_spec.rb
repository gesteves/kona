require "rails_helper"

RSpec.describe "Widgets::Articles trending", type: :request do
  # Makes an article with the fields that Articles#list gives.
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

  let(:corpus) { [ art_newest, art_april, art_march, art_february, art_spiking, art_steady, art_short ] }

  # a5 has a surge: a small recent count on a very small baseline. a6 is always popular: it has much
  # traffic, and that traffic agrees with its own high baseline. Each other article has no traffic.
  # Thus the order is a5, then a6, then the other articles by date.
  def rows(by_path)
    by_path.map { |path, total| { dimensions: [ path ], metrics: [ total ] } }
  end

  before do
    allow_any_instance_of(Articles).to receive(:list).and_return(corpus)
    recent = rows(art_spiking.path => 15, art_steady.path => 72)
    baseline = rows(art_spiking.path => 30, art_steady.path => 2000)
    # The recent window and the baseline are two event:page queries over two ranges. The length of
    # the range selects the answer: the recent range is short, and the baseline range is
    # approximately one month.
    allow_any_instance_of(Plausible).to receive(:query) do |**kwargs|
      first, last = kwargs[:date_range]
      span_hours = (Time.parse(last) - Time.parse(first)) / 3600.0
      { results: span_hours <= (TrendingArticles::RECENT_WINDOW_HOURS + 1) ? recent : baseline }
    end
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    # cached_json puts the order in the cache. This stubs Redis, thus the suite needs no Redis and no
    # example gives its cached result to another one.
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  it_behaves_like "a live-update fragment", "/widgets/articles/trending"

  describe "GET /widgets/articles/trending (all)" do
    it "renders the trending-articles section as a live-update fragment" do
      get "/widgets/articles/trending", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('class="collection collection--halves"')
      expect(response.body).to include("Trending Articles")
      expect(response.body).to include('data-controller="live-update"')
      expect(response.body).to include('data-live-update-url-value="/widgets/articles/trending"')
    end

    it "includes recent articles, excludes Shorts, and orders the rest by trending score" do
      get "/widgets/articles/trending", headers: auth_headers

      expect(response.body).to include("Spiking Article")
      expect(response.body).to include("Steady Article")
      expect(response.body).to include("Newest Article") # recent articles are NOT excluded here
      expect(response.body).not_to include("A Short Post") # Shorts are excluded
      expect(response.body.index("Spiking Article")).to be < response.body.index("Steady Article")
    end

    it "links each card to the article's computed path" do
      get "/widgets/articles/trending", headers: auth_headers

      expect(response.body).to include('href="/2024/01/01/spiking/"')
    end

    it "sets a one-hour edge caching header" do
      get "/widgets/articles/trending", headers: auth_headers

      cache_control = response.headers["Cache-Control"]
      expect(cache_control).to include("public")
      expect(cache_control).to include("max-age=0")
      expect(cache_control).to include("stale-while-revalidate=3600")

      edge = response.headers["CDN-Cache-Control"]
      expect(edge).to include("public")
      expect(edge).to include("max-age=3600")
      expect(edge).to include("stale-while-revalidate=86400")
    end

    context "when there are no articles" do
      before { allow_any_instance_of(Articles).to receive(:list).and_return([]) }

      it "returns an empty body so the placeholder collapses" do
        get "/widgets/articles/trending", headers: auth_headers

        expect(response).to have_http_status(:ok)
        expect(response.body.strip).to be_empty
      end
    end

    it "requires the API_TOKEN bearer (the proxy injects it; direct hits are rejected)" do
      get "/widgets/articles/trending"
      expect(response).to have_http_status(:unauthorized)

      get "/widgets/articles/trending", headers: { "Authorization" => "Bearer wrong" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /widgets/articles/trending/:id" do
    it "drops the given article and advertises the path as its refetch URL" do
      get "/widgets/articles/trending/a5", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Spiking Article") # a5 is excluded
      expect(response.body).to include("Steady Article")       # a non-excluded article still trends
      expect(response.body).to include("Newest Article")
      expect(response.body).to include('data-live-update-url-value="/widgets/articles/trending/a5"')
    end

    it "ignores a malformed id (serves full trending) and never errors" do
      get "/widgets/articles/trending/@@@", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Spiking Article") # nothing excluded
      expect(response.body).to include("Steady Article")
    end

    it "requires the API_TOKEN bearer" do
      get "/widgets/articles/trending/a5"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end

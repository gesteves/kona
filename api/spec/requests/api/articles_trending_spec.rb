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

  # 4 newest = "recent" (excluded from non_recent); the 2 oldest remain. Of those, the spiking one
  # scores high (recent 1d views far above its all-time average), the steady one scores 0.
  let(:art_newest)   { article(id: "a1", title: "Newest Article",   slug: "newest",   published_at: "2024-12-30T10:00:00Z") }
  let(:art_april)    { article(id: "a2", title: "April Article",    slug: "april",    published_at: "2024-04-01T10:00:00Z") }
  let(:art_march)    { article(id: "a3", title: "March Article",    slug: "march",    published_at: "2024-03-01T10:00:00Z") }
  let(:art_february) { article(id: "a4", title: "February Article", slug: "february", published_at: "2024-02-01T10:00:00Z") }
  let(:art_spiking)  { article(id: "a5", title: "Spiking Article",  slug: "spiking",  published_at: "2024-01-01T10:00:00Z") }
  let(:art_steady)   { article(id: "a6", title: "Steady Article",   slug: "steady",   published_at: "2023-12-01T10:00:00Z") }
  let(:art_short)    { article(id: "s1", title: "A Short Post",     slug: "short",     published_at: "2024-06-01T10:00:00Z", entry_type: "Short") }

  let(:corpus) { [art_newest, art_april, art_march, art_february, art_spiking, art_steady, art_short] }

  # Only the spiking article has any pageviews; everything else scores 0.
  let(:metrics) do
    {
      "all" => { art_spiking.path => 100 },
      "30d" => { art_spiking.path => 90 },
      "7d"  => { art_spiking.path => 70 },
      "1d"  => { art_spiking.path => 50 }
    }
  end

  before do
    allow_any_instance_of(Articles).to receive(:list).and_return(corpus)
    allow_any_instance_of(Plausible).to receive(:query) do |_instance, **kwargs|
      rows = (metrics[kwargs[:date_range]] || {}).map { |path, pv| { dimensions: [path], metrics: [pv] } }
      { results: rows }
    end
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    # The ranking is cached via cached_json; stub Redis so the suite stays Redis-free and examples
    # don't leak cached results into each other.
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  it "renders the trending-articles section as a live-update fragment" do
    get "/api/articles/trending", headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('class="collection collection--halves"')
    expect(response.body).to include("Trending Articles")
    expect(response.body).to include('data-controller="live-update"')
    expect(response.body).to include('data-live-update-url-value="/api/articles/trending"')
  end

  it "excludes Shorts and the most-recent articles, and orders the rest by trending score" do
    get "/api/articles/trending", headers: auth_headers

    expect(response.body).to include("Spiking Article")
    expect(response.body).to include("Steady Article")
    expect(response.body).not_to include("A Short Post")    # Shorts are excluded
    expect(response.body).not_to include("Newest Article")  # excluded as a recent article
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
end

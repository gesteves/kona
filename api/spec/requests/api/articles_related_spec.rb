require "rails_helper"

RSpec.describe "Api::Articles related", type: :request do
  def article(id:, title:, slug:, published_at:, summary: "A short summary.", entry_type: "Article", draft: false)
    path = "/#{DateTime.parse(published_at).strftime('%Y/%m/%d')}/#{slug}/"
    DeepOstruct.wrap(
      title: title, slug: slug, summary: summary, published_at: published_at,
      entry_type: entry_type, draft: draft, path: path, sys: { id: id }
    )
  end

  let(:related) do
    [
      article(id: "r1", title: "First Related", slug: "first", published_at: "2024-04-01T10:00:00Z"),
      article(id: "r2", title: "Second Related", slug: "second", published_at: "2024-03-01T10:00:00Z")
    ]
  end

  before do
    allow_any_instance_of(RelatedArticles).to receive(:for_article).and_return(related)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  describe "GET /api/articles/related/:id" do
    it "renders the You May Also Like section as a live-update fragment" do
      get "/api/articles/related/abc123", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('class="collection collection--halves"')
      expect(response.body).to include("You May Also Like")
      expect(response.body).to include('data-controller="live-update"')
      expect(response.body).to include('data-live-update-url-value="/api/articles/related/abc123"')
    end

    it "renders a card per related article, linking to its computed path" do
      get "/api/articles/related/abc123", headers: auth_headers

      expect(response.body).to include("First Related")
      expect(response.body).to include("Second Related")
      expect(response.body).to include('href="/2024/04/01/first/"')
    end

    it "sets a one-hour durable caching header" do
      get "/api/articles/related/abc123", headers: auth_headers

      cache_control = response.headers["Cache-Control"]
      expect(cache_control).to include("public")
      expect(cache_control).to include("max-age=0")

      edge = response.headers["Netlify-CDN-Cache-Control"]
      expect(edge).to include("durable")
      expect(edge).to include("max-age=3600")
      expect(edge).to include("stale-while-revalidate=86400")
    end

    context "when there are no related articles" do
      before { allow_any_instance_of(RelatedArticles).to receive(:for_article).and_return([]) }

      it "returns an empty body so the placeholder collapses" do
        get "/api/articles/related/abc123", headers: auth_headers

        expect(response).to have_http_status(:ok)
        expect(response.body.strip).to be_empty
      end
    end

    it "returns an empty body for a malformed id without invoking the service" do
      expect_any_instance_of(RelatedArticles).not_to receive(:for_article)
      get "/api/articles/related/@@@", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
    end

    it "requires the API_TOKEN bearer (the proxy injects it; direct hits are rejected)" do
      get "/api/articles/related/abc123"
      expect(response).to have_http_status(:unauthorized)

      get "/api/articles/related/abc123", headers: { "Authorization" => "Bearer wrong" }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
